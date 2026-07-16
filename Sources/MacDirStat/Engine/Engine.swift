import CDirstatCore
import Foundation

// =============================================================================
// FILE: Sources/MacDirStat/Engine/Engine.swift
// =============================================================================
//
// PURPOSE
//   The entire Swift side of the FFI seam to the dirstat-core Rust engine
//   (C ABI). This is the ONLY file in the app where raw pointers, C structs,
//   or `ds_*` symbols appear (APP-FFI-1). Everything above this layer sees
//   idiomatic value types and opaque `NodeID` handles: the engine owns the
//   tree, Swift fetches node details lazily for visible rows and treemap
//   geometry as one bulk buffer per relayout (APP-FFI-2). The key design
//   decision: never copy the tree into Swift — hold handles, ask the engine.
//
// UPSTREAM DEPENDENCIES (what this file consumes)
//   - CDirstatCore (Sources/CDirstatCore/include/dirstat_core.h): the pinned
//     generated C header — DsNodeInfo/DsTmRect/DsScanOptions structs and all
//     ds_* entry points. The header is checked in and version-pinned; see
//     verifyABI below.
//   - Foundation: Date, DispatchQueue (main-actor marshalling of progress),
//     strdup/free for C string-array marshalling.
//
// DOWNSTREAM CONSUMERS (who depends on this file)
//   - Model/AppState.swift: EngineScan (scan lifecycle), EngineModel (all
//     reads), NodeID (selection/zoom), ScanProgress, SizeMetric, ChildSort.
//   - Model/CleanupStore.swift: EngineModel.path/info/refresh, NodeID,
//     KindCategory for staged items.
//   - Model/Palette.swift: TreemapRect + KindCategory as color keys.
//   - Views/TreemapPane.swift: EngineModel.treemapLayout + TreemapRect.
//   - Views/MainView.swift / SidebarOutline.swift / TypeTableSheet.swift /
//     CleanupReviewSheet.swift: NodeInfo, CategoryStat, TypeStat,
//     VolumeReconciliation via AppState.
//   - MacDirStatApp.swift: Engine.verifyABI at launch, SizeMetric menu tags.
//
// STRUCTURE
//   - Engine: ABI pin (verifyABI) + last-error retrieval
//   - EngineError: Swift Error carrying the engine's last_error detail
//   - NodeID / KindCategory / NodeInfo / TreemapRect / TypeStat /
//     CategoryStat / VolumeReconciliation: value types bridged from C
//   - ChildSort / SizeMetric / TreemapAlgorithm: enums mirroring C constants
//   - ScanProgress + ProgressBox: progress plumbing across the C boundary
//   - EngineScan: a running scan; owns the scan handle + progress trampoline
//   - EngineModel: a scanned model; owns model lifetime and every read call
//
// BEHAVIOR & INVARIANTS
//   - Progress callbacks arrive on ENGINE threads; they are marshalled to
//     the main queue before touching app state (APP-FFI-3).
//   - Model lifetime is deterministic: EngineModel.deinit frees the model;
//     NodeIDs are only meaningful against the model that produced them
//     (APP-FFI-4).
//   - Every failing engine call surfaces as EngineError with the engine's
//     own last_error text — no silent failures (APP-FFI-5).
//   - During a scan the model may be read concurrently; the engine contract
//     is that its numbers only grow (the basis of design 1d progressive UI).
// =============================================================================

// MARK: - ABI pin & error surface

/// Swift wrapper for the dirstat-core C ABI (APP-FFI-1). This file is the
/// only place raw pointers appear; the rest of the app sees idiomatic
/// Swift types and opaque `NodeID` handles (APP-FFI-2).
enum Engine {
    /// Header/library version pin (APP-FFI-6): refuse to run against a
    /// mismatched pair. `DS_ABI_VERSION` comes from the checked-in header;
    /// `ds_abi_version()` from the linked library.
    ///
    /// Why this matters: Swift lays out `DsNodeInfo`/`DsTmRect` reads and
    /// picks argument registers from the CHECKED-IN header, while the actual
    /// code executing lives in the separately built `libdirstat_core.a`. If
    /// the two drift (a field added, an enum renumbered), every struct read
    /// becomes silent memory corruption — wrong sizes, garbage flags, or
    /// crashes far from the cause. Skipping this check would trade one loud
    /// startup crash (with a "rebuild the engine" message) for undefined
    /// behavior at some arbitrary later call.
    ///
    /// Called from `MacDirStatApp.init` at launch and defensively again in
    /// `EngineScan.init` before the first real engine call.
    static func verifyABI() {
        let linked = ds_abi_version()
        precondition(
            linked == UInt32(DS_ABI_VERSION),
            "dirstat-core ABI mismatch: header \(DS_ABI_VERSION), library \(linked). Rebuild the engine (make engine)."
        )
    }

    /// Engine errors surface as Swift errors with detail (APP-FFI-5).
    ///
    /// Uses the same two-call size-then-fill pattern as `stringCall` below:
    /// first call with a nil buffer returns the byte count needed (including
    /// the NUL terminator), second call fills the allocated buffer.
    static func lastError() -> String {
        let needed = ds_last_error(nil, 0)
        guard needed > 0 else { return "unknown engine error" }
        var buf = [CChar](repeating: 0, count: Int(needed))
        _ = ds_last_error(&buf, buf.count)
        return String(cString: buf)
    }
}

/// A failed engine call, carrying the engine's own `last_error` text so no
/// failure is ever silent (APP-FFI-5). Construct via `fromEngine()`
/// immediately after the failing `ds_*` call, before any other engine call
/// can overwrite the thread's last-error slot.
struct EngineError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
    /// Snapshot the engine's current last-error string into a Swift Error.
    static func fromEngine() -> EngineError { EngineError(message: Engine.lastError()) }
}

// MARK: - Value types bridged from the C structs

/// Opaque node handle. Valid for the life of its `EngineModel` (APP-FFI-4).
/// Zero is the engine's "no node" sentinel — hence `invalid`/`isValid`.
/// Cheap to copy and Hashable, so it doubles as the app-wide selection,
/// zoom-root, and cleanup-staging key.
struct NodeID: Hashable {
    /// The engine's raw 64-bit node identifier; 0 means "no node".
    let raw: UInt64
    static let invalid = NodeID(raw: 0)
    var isValid: Bool { raw != 0 }
}

/// Kind categories (engine `Category`, design 1g). RGB lives app-side.
/// Raw values MUST match the engine's numbering (developer = 0 …); the
/// bridging inits below fall back to `.other` for any future value the
/// engine adds, so an engine upgrade degrades gracefully instead of crashing.
enum KindCategory: UInt8, CaseIterable, Identifiable {
    case developer = 0, media, photos, documents, archives, system, apps, other
    var id: UInt8 { rawValue }

    /// Human-readable chip/legend label for the category (design 1b chips).
    var label: String {
        switch self {
        case .developer: "Developer"
        case .media: "Audio & Video"
        case .photos: "Photos"
        case .documents: "Documents"
        case .archives: "Archives & Images"
        case .system: "System & Caches"
        case .apps: "Applications"
        case .other: "Other"
        }
    }
}

/// A lazily-fetched snapshot of one node's facts (sizes, counts, flags,
/// color keys), bridged from the C `DsNodeInfo` struct. Fetched only for
/// nodes the UI actually looks at — visible outline rows, the selection,
/// staged cleanup items — never for the whole tree (APP-FFI-2).
struct NodeInfo {
    let id: NodeID
    /// Parent handle; invalid (0) at the scan root.
    let parent: NodeID
    /// Apparent byte size (what `ls -l` reports; inflated by cloud
    /// placeholders and APFS clones — see `SizeMetric`).
    let logical: UInt64
    /// Allocated-on-disk byte size; the truthful default metric.
    let physical: UInt64
    let files: UInt64
    let subdirs: UInt64
    let items: UInt64
    /// Last-modified time; nil when the engine reported 0 (unknown).
    let mtime: Date?
    /// Number of direct children — drives the outline disclosure triangle.
    let childCount: Int
    let isDirectory: Bool
    let isSymlink: Bool
    /// Permission-denied during scan; feeds the "unreadable" amber UI.
    let isUnreadable: Bool
    /// Same directory inode already counted via another path (APFS
    /// firmlink / bind mount); shown but contributes nothing.
    let isAliasDuplicate: Bool
    /// The name is not valid UTF-8, so `path(of:)`'s lossy string can denote
    /// a DIFFERENT real file. Destructive actions must be refused on such
    /// nodes (security: confused-deputy deletion — dirstat-core#5). macOS
    /// filesystems reject such names at creation, but network/foreign mounts
    /// can surface them, so the app defends anyway.
    let hasNonUTF8Name: Bool
    /// The three 1g color-channel keys (kind / age / extension). Values
    /// only; the RGB mapping lives in Palette.swift.
    let category: KindCategory
    let ageBucket: Int
    let extSlot: Int

    /// Bridge from the raw C struct: unpack the packed `kind` byte and
    /// `flags` bitfield into typed booleans, and treat mtime 0 as unknown.
    /// `fileprivate` — only `EngineModel.info` may construct these.
    fileprivate init(_ c: DsNodeInfo) {
        id = NodeID(raw: c.id)
        parent = NodeID(raw: c.parent)
        logical = c.logical
        physical = c.physical
        files = c.files
        subdirs = c.subdirs
        items = c.items
        mtime = c.mtime > 0 ? Date(timeIntervalSince1970: TimeInterval(c.mtime)) : nil
        childCount = Int(c.child_count)
        isDirectory = c.kind == 1
        isSymlink = c.kind == 2
        isUnreadable = c.flags & UInt32(DS_NODE_FLAG_UNREADABLE) != 0
        isAliasDuplicate = c.flags & UInt32(DS_NODE_FLAG_DUPLICATE) != 0
        hasNonUTF8Name = c.flags & UInt32(DS_NODE_FLAG_NON_UTF8) != 0
        category = KindCategory(rawValue: c.category) ?? .other
        ageBucket = Int(c.age_bucket)
        extSlot = Int(c.ext_slot)
    }
}

/// One rectangle of engine-computed treemap geometry (APP-TM-1: the app
/// never computes geometry, only pixels). Coordinates are in the points the
/// layout was requested with. Carries the 1g color keys and depth so the
/// renderer needs no further engine round-trips per rect.
struct TreemapRect {
    let node: NodeID
    let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    /// Nesting depth from the layout root (0 = root); used for hit-test
    /// precedence (deepest wins) and directory hairline styling.
    let depth: Int
    /// Directories get hairline outlines and group labels; only leaf (file)
    /// rects get color fills.
    let isDir: Bool
    let category: KindCategory
    let ageBucket: Int
    let extSlot: Int
    var frame: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

/// One row of the engine's per-extension aggregation (the ⌘T type table).
struct TypeStat: Identifiable {
    let ext: String
    let logical: UInt64
    let files: UInt64
    /// 0..11 distinct palette slot, 12 = "other".
    let slot: Int
    var id: String { ext }
}

/// Per-kind totals for the legend chips and capacity footer (design 1b).
/// Carries both metrics so the UI can follow the user's `SizeMetric` toggle
/// without re-querying the engine.
struct CategoryStat: Identifiable {
    let category: KindCategory
    let logical: UInt64
    let physical: UInt64
    let files: UInt64
    var id: UInt8 { category.rawValue }

    /// The byte count for the currently selected size metric.
    func bytes(_ metric: SizeMetric) -> UInt64 {
        metric == .physical ? physical : logical
    }
}

/// The engine's capacity reconciliation for the scanned volume, derived
/// from the total/free figures the host supplied via `setVolumeFigures`.
struct VolumeReconciliation {
    let total: UInt64
    let free: UInt64
    /// The "N GB unreadable" number: capacity − free − measured, engine math.
    let unknown: UInt64
}

/// Child sort keys for `EngineModel.children`; raw values match the C
/// constants. Sorting happens in the engine, within one parent, with a
/// stable secondary key (APP-DIR-2/3).
enum ChildSort: UInt8 {
    case size = 0, name = 1, items = 2, mtime = 3, physicalSize = 4
}

/// Which byte count drives sizes, sorting, and treemap area. Physical
/// (allocated-on-disk) is the truthful default on modern macOS: cloud
/// placeholders (OneDrive/iCloud dataless files) report full logical size
/// while occupying ~nothing, and APFS clones double-report logically.
enum SizeMetric: UInt8 {
    case logical = 0
    case physical = 1
}

/// Treemap layout algorithm choice, passed through to the engine per
/// layout call (APP-TM-3). Raw values match the C constants.
enum TreemapAlgorithm: UInt8 {
    case kdirstat = 0
    case squarified = 1
}

// MARK: - Scan progress plumbing

/// Progress snapshot, already hopped to the main actor (APP-FFI-3).
/// `done` marks the final callback of a scan (completed or cancelled).
struct ScanProgress {
    let items: UInt64
    let bytes: UInt64
    let currentPath: String
    let done: Bool
}

/// Reference-typed box around the Swift progress closure, existing purely
/// so the closure can cross the C boundary.
///
/// The problem: `ds_scan_begin` takes a plain C function pointer plus a
/// `void *user` context. A `@convention(c)` Swift closure cannot capture
/// anything (there is nowhere to store captures in a bare function
/// pointer), so the actual Swift handler must travel through `user`. Only
/// class instances can round-trip through `Unmanaged`/`toOpaque`, hence
/// this box.
///
/// Lifetime: `EngineScan` passes the box UNRETAINED (no +1) to the engine
/// and instead keeps its own strong reference (`progressBox` property) for
/// the scan's whole life. `EngineScan.deinit` cancels AND JOINS the engine
/// threads before releasing anything, which is the guarantee that no engine
/// thread can call back into a deallocated box.
private final class ProgressBox {
    /// `@Sendable`: invoked on arbitrary engine threads.
    let handler: @Sendable (ScanProgress) -> Void
    init(_ handler: @escaping @Sendable (ScanProgress) -> Void) { self.handler = handler }
}

// MARK: - EngineScan: a running scan

/// A running scan. Owns the engine scan handle; `model` is safe to read
/// progressively while scanning (the engine's numbers only grow — the
/// contract behind design 1d).
///
/// Ownership: this class owns three things whose lifetimes must nest —
/// the scan handle (freed in deinit), the `ProgressBox` (must outlive all
/// engine threads; see deinit's cancel + join ordering), and the
/// `EngineModel` (which outlives the scan and frees itself independently).
final class EngineScan {
    /// The engine's opaque scan handle; freed exactly once, in deinit.
    private let handle: OpaquePointer
    /// The model being built. Readable mid-scan; retained by AppState after
    /// the scan finishes, so it can outlive this object.
    let model: EngineModel
    /// Strong reference keeping the callback context alive — the engine
    /// only holds an UNRETAINED pointer to this box (see init).
    private let progressBox: ProgressBox?

    /// Progress callbacks arrive on engine threads; the wrapper marshals
    /// them to the main queue before they reach app state (APP-FFI-3).
    /// `skipPaths` are absolute directories the engine must not descend
    /// into — platform knowledge the app supplies (the APFS volume-group
    /// service paths, so firmlinked trees are never traversed twice).
    ///
    /// - Parameters:
    ///   - root: absolute path the engine walks.
    ///   - skipPaths: exact-match directories the engine must not enter.
    ///   - onProgress: called on the MAIN queue with monotonically growing
    ///     counters; the final call has `done == true`.
    /// - Throws: `EngineError` if the engine refuses to start the scan.
    init(
        root: String, skipPaths: [String] = [],
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) throws {
        // Defensive re-check of the header/library pin before the first
        // real FFI call of a scan (cheap; already checked at app launch).
        Engine.verifyABI()
        // Step 1: wrap the caller's handler in a box that hops to the main
        // queue. The hop happens HERE, inside the box, so the trampoline
        // below stays capture-free and every consumer automatically gets
        // main-thread delivery (APP-FFI-3).
        let box = ProgressBox { progress in
            DispatchQueue.main.async { onProgress(progress) }
        }
        // Step 2: erase the box to a raw pointer for the C `user` context.
        // passUnretained = no +1 retain; the engine never owns the box.
        // Instead `self.progressBox` (set at the end of init) keeps it
        // alive, and deinit joins the engine threads before that strong
        // reference can die — that ordering is the entire safety argument.
        let user = Unmanaged.passUnretained(box).toOpaque()
        // Step 3: the @convention(c) trampoline. It MUST capture nothing
        // (a C function pointer has no closure context — the compiler
        // rejects captures), so all state arrives via the `user` pointer.
        // It runs on an engine thread: it only rehydrates the box
        // (takeUnretainedValue = borrow, no release), copies the C string
        // while the pointer is still valid, and hands off to the box.
        let callback: @convention(c) (
            UInt64, UInt64, UnsafePointer<CChar>?, UInt8, UnsafeMutableRawPointer?
        ) -> Void = { items, bytes, path, done, user in
            guard let user else { return }
            let box = Unmanaged<ProgressBox>.fromOpaque(user).takeUnretainedValue()
            // Copy the path immediately — the C pointer is only valid for
            // the duration of this callback.
            let pathString = path.map { String(cString: $0) } ?? ""
            box.handler(
                ScanProgress(items: items, bytes: bytes, currentPath: pathString, done: done == 1))
        }
        // Step 4: start the scan. The skip-path C array only needs to live
        // through ds_scan_begin (the engine copies it), which is exactly
        // the lifetime withCStringArray provides.
        let handle: OpaquePointer? = Self.withCStringArray(skipPaths) { argv, count in
            var options = DsScanOptions()
            options.skip_paths = argv
            options.skip_paths_len = count
            // Directory-bomb ceiling (dirstat-core#11): generous enough that
            // a real volume (tens of millions of items) never trips it, but
            // a degenerate/hostile tree fails with a partial result + report
            // note instead of exhausting memory.
            options.max_nodes = 50_000_000
            return root.withCString { ds_scan_begin($0, &options, callback, user) }
        }
        guard let handle else {
            throw EngineError.fromEngine()
        }
        // Step 5: fetch the model handle that grows as the scan proceeds.
        // If that fails, the scan handle must be freed here — deinit will
        // never run for a throwing init.
        guard let modelPtr = ds_scan_model(handle) else {
            ds_scan_free(handle)
            throw EngineError.fromEngine()
        }
        self.handle = handle
        self.progressBox = box
        self.model = EngineModel(taking: modelPtr)
    }

    /// Whether the engine has finished walking (completed or cancelled).
    var isComplete: Bool { ds_scan_is_complete(handle) == 1 }

    /// Stop keeps everything found so far (design 1d).
    /// Asynchronous: the engine winds down and delivers a final done=true
    /// progress callback; the partial model stays fully usable.
    func cancel() { ds_scan_cancel(handle) }

    /// Teardown ordering is load-bearing: cancel asks engine threads to
    /// stop, join BLOCKS until they have all exited, and only then is the
    /// handle freed. Joining before free is what guarantees no engine
    /// thread can still fire the trampoline into the (unretained)
    /// ProgressBox after this object — and the box it owns — deallocate.
    deinit {
        ds_scan_cancel(handle)
        ds_scan_join(handle)
        ds_scan_free(handle)
    }

    /// Marshal a Swift string array as a `const char *const *` valid for
    /// the duration of `body` (the engine copies during `ds_scan_begin`).
    ///
    /// Lifetime rules: `String.withCString` pointers only live inside their
    /// own closure, so nesting N of them for an array is impossible without
    /// recursion. Instead each string is `strdup`ed onto the heap, an array
    /// of those pointers is exposed via `withUnsafeBufferPointer`, and the
    /// deferred `free` releases every copy AFTER `body` returns. The engine
    /// must not keep the array past the call — and per its contract it
    /// copies during `ds_scan_begin`, so it does not.
    private static func withCStringArray<R>(
        _ strings: [String], _ body: (UnsafePointer<UnsafePointer<CChar>?>?, Int) -> R
    ) -> R {
        // Empty array: pass NULL/0 straight through, nothing to allocate.
        guard !strings.isEmpty else { return body(nil, 0) }
        // Heap-copy each string; strdup never returns nil here in practice
        // (small allocations), and the copies are freed on every exit path.
        let duplicated: [UnsafeMutablePointer<CChar>] = strings.map { strdup($0)! }
        defer { duplicated.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>?] = duplicated.map { UnsafePointer($0) }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress, strings.count) }
    }
}

// MARK: - EngineModel: a scanned model

/// A scanned model. The engine owns the tree; this class owns the model
/// lifetime and frees it deterministically (APP-FFI-4).
///
/// `@unchecked Sendable`: the class holds only the opaque engine pointer,
/// and the engine's documented thread-safety contract makes all
/// `ds_model_*`/`ds_treemap_*` reads (and `ds_refresh_node` absent a
/// concurrent scan) safe from any thread. Swift cannot verify a contract
/// that lives on the other side of the FFI, hence "unchecked" — the
/// compiler is being told, not shown. This is what lets AppState.rescan
/// hand the model to a detached background task while the main actor keeps
/// reading it (APP-TM-10-style responsiveness).
final class EngineModel: @unchecked Sendable {
    /// The engine's opaque model pointer. Never exposed; every method is a
    /// thin, self-contained FFI call against it.
    private let ptr: OpaquePointer

    /// "taking": ownership transfer — this object is now responsible for
    /// the pointer and will `ds_model_free` it exactly once (APP-FFI-4).
    /// `fileprivate` so only `EngineScan` can mint models.
    fileprivate init(taking ptr: OpaquePointer) {
        self.ptr = ptr
    }

    /// Deterministic model teardown (APP-FFI-4). All NodeIDs handed out by
    /// this model become dangling from the engine's point of view; the app
    /// discards them by dropping selection/zoom state when models change.
    deinit { ds_model_free(ptr) }

    /// Handle of the scan root (invalid while the model is still empty).
    var root: NodeID { NodeID(raw: ds_model_root(ptr)) }

    /// Live scan totals; `complete` flips once, `errorCount` sizes the
    /// scan report. Safe to poll mid-scan.
    var stats: (items: UInt64, bytes: UInt64, complete: Bool, errorCount: UInt64) {
        var s = DsScanStats()
        _ = ds_model_stats(ptr, &s)
        return (s.items, s.bytes, s.complete == 1, s.error_count)
    }

    /// Fetch one node's facts. Throws `EngineError` for a stale/unknown
    /// id — callers use `try?` where "node vanished" is an expected state
    /// (e.g. after a cleanup commit removed it).
    func info(_ id: NodeID) throws -> NodeInfo {
        var c = DsNodeInfo()
        guard ds_node_info(ptr, id.raw, &c) == 0 else { throw EngineError.fromEngine() }
        return NodeInfo(c)
    }

    /// Display name (last path component); empty for an invalid id.
    func name(of id: NodeID) -> String {
        stringCall { ds_node_name(ptr, id.raw, $0, $1) }
    }

    /// Absolute filesystem path; the bridge to every OS-side action
    /// (Reveal in Finder, Copy Path, Move to Trash, cleanup guards).
    func path(of id: NodeID) -> String {
        stringCall { ds_node_path(ptr, id.raw, $0, $1) }
    }

    /// Sorted child enumeration — sorting happens in the engine
    /// (within-parent only, stable), the app just renders (APP-DIR-2).
    ///
    /// Two-call size-then-fill pattern, same as `stringCall`: the first
    /// call (nil buffer) returns the child count, the second fills the
    /// sized buffer. `written` may be less than `total` if the tree changed
    /// between the calls mid-scan, hence the min() when slicing.
    func children(of id: NodeID, sort: ChildSort = .size, descending: Bool = true) -> [NodeID] {
        let total = ds_node_children(ptr, id.raw, sort.rawValue, descending ? 1 : 0, nil, 0)
        guard total > 0 else { return [] }
        var buf = [UInt64](repeating: 0, count: Int(total))
        let written = buf.withUnsafeMutableBufferPointer {
            ds_node_children(ptr, id.raw, sort.rawValue, descending ? 1 : 0, $0.baseAddress, $0.count)
        }
        guard written >= 0 else { return [] }
        return buf.prefix(Int(min(written, total))).map { NodeID(raw: $0) }
    }

    /// Engine-computed share of the root's bytes, 0–100.
    func percentOfRoot(_ id: NodeID) -> Double { ds_node_percent_of_root(ptr, id.raw) }

    /// Full extension table (the ⌘T popover, design 1b).
    ///
    /// Single-call variant: a generously sized buffer is filled directly
    /// (the engine returns the row count). The extension arrives as a
    /// fixed-size inline C char array inside DsTypeStat, not a pointer, so
    /// it is decoded by scanning its raw bytes up to the first NUL.
    func typeList(max: Int = 512) -> [TypeStat] {
        var buf = [DsTypeStat](repeating: DsTypeStat(), count: max)
        let total = buf.withUnsafeMutableBufferPointer {
            ds_type_list(ptr, $0.baseAddress, $0.count)
        }
        guard total > 0 else { return [] }
        return buf.prefix(min(Int(total), max)).map { c in
            // Copy the fixed-size array out of the struct so its bytes can
            // be viewed; decode as UTF-8 up to the NUL terminator.
            var extBytes = c.ext
            let ext = withUnsafeBytes(of: &extBytes) { raw -> String in
                let data = raw.prefix(while: { $0 != 0 })
                return String(decoding: data, as: UTF8.self)
            }
            return TypeStat(ext: ext, logical: c.logical, files: c.files, slot: Int(c.slot))
        }
    }

    /// Per-category totals for the legend chips + capacity footer (1b).
    /// Fixed buffer of 8: KindCategory has exactly 8 cases by contract.
    func categoryList() -> [CategoryStat] {
        var buf = [DsCategoryStat](repeating: DsCategoryStat(), count: 8)
        let n = buf.withUnsafeMutableBufferPointer {
            ds_category_list(ptr, $0.baseAddress, $0.count)
        }
        guard n > 0 else { return [] }
        return buf.prefix(8).map {
            CategoryStat(
                category: KindCategory(rawValue: $0.category) ?? .other,
                logical: $0.logical,
                physical: $0.physical,
                files: $0.files)
        }
    }

    /// Host supplies capacity/free (APP-TARGET-3); engine owns the
    /// `<Unknown>` reconciliation math.
    func setVolumeFigures(total: UInt64, free: UInt64) {
        _ = ds_model_set_volume(ptr, total, free)
    }

    /// The engine's capacity math; nil until `setVolumeFigures` was called.
    /// Drives the capacity footer bar and the amber "unreadable" number.
    var volumeReconciliation: VolumeReconciliation? {
        var v = DsVolumeInfo()
        guard ds_model_volume(ptr, &v) == 0 else { return nil }
        return VolumeReconciliation(total: v.total, free: v.free, unknown: v.unknown)
    }

    /// Scan error strings (denied paths etc.), capped at 500 for the UI.
    var scanReport: [String] {
        let count = stats.errorCount
        return (0..<min(count, 500)).map { i in
            stringCall { ds_model_error(ptr, i, $0, $1) }
        }
    }

    /// One bulk buffer per (re)layout (APP-FFI-2 / CORE-FFI-6), converted
    /// to Swift values and freed before returning.
    ///
    /// Buffer ownership: the ENGINE allocates the rect array and hands back
    /// a pointer + count; ownership transfers to the caller, who must
    /// return it via `ds_treemap_free`. The `defer` frees it after — and
    /// only after — every rect has been copied into Swift `TreemapRect`
    /// values by the `map`, so nothing escaping this function ever aliases
    /// engine memory. On any engine error the guard returns `[]` before a
    /// buffer exists, so there is nothing to free on that path.
    ///
    /// - Parameters:
    ///   - root: subtree to lay out (the current zoom root).
    ///   - width/height: target size in points; mid-scan the app passes a
    ///     scaled-down width so the map fills only the scanned fraction.
    ///   - minPixel: rects smaller than this are culled by the engine.
    ///   - metric: which byte count drives rect areas.
    func treemapLayout(
        root: NodeID, width: CGFloat, height: CGFloat,
        algorithm: TreemapAlgorithm = .squarified, minPixel: CGFloat = 2,
        metric: SizeMetric = .physical
    ) -> [TreemapRect] {
        var rects: UnsafeMutablePointer<DsTmRect>?
        var count = 0
        guard
            ds_treemap_layout(
                ptr, root.raw, Float(width), Float(height), algorithm.rawValue,
                Float(minPixel), metric.rawValue, &rects, &count) == 0, let rects
        else { return [] }
        // Free the engine buffer after the map below has deep-copied it.
        defer { ds_treemap_free(rects, count) }
        return UnsafeBufferPointer(start: rects, count: count).map { c in
            TreemapRect(
                node: NodeID(raw: c.node),
                x: CGFloat(c.x), y: CGFloat(c.y), w: CGFloat(c.w), h: CGFloat(c.h),
                depth: Int(c.depth), isDir: c.is_dir == 1,
                category: KindCategory(rawValue: c.category) ?? .other,
                ageBucket: Int(c.age_bucket), extSlot: Int(c.ext_slot))
        }
    }

    /// After the app mutates the filesystem (Move to Trash), re-read the
    /// node so aggregates, chips, footer, and map reconcile (APP-ACT-12,
    /// design 1e "the map animates the space returning").
    func refresh(_ id: NodeID) throws {
        guard ds_refresh_node(ptr, id.raw) == 0 else { throw EngineError.fromEngine() }
    }

    /// Root-ward chain for reveal/expand coupling (APP-COUPLE-2).
    /// Returned root-first (root … node) so callers can expand ancestors
    /// in order. Terminates at the root, whose parent id is invalid (0).
    func pathToRoot(_ id: NodeID) -> [NodeID] {
        var chain: [NodeID] = []
        var cur = id
        while cur.isValid, let nodeInfo = try? self.info(cur) {
            chain.append(cur)
            cur = nodeInfo.parent
        }
        return chain.reversed()
    }

    /// The engine's universal string convention, wrapped once: every
    /// string-returning entry point is "call with nil to learn the byte
    /// count (incl. NUL), call again with a buffer that size to fill it".
    /// Two calls instead of a guessed buffer — no truncation, no
    /// over-allocation, and the engine never allocates memory Swift would
    /// have to free. Returns "" when the engine reports nothing (<= 0).
    private func stringCall(_ f: (UnsafeMutablePointer<CChar>?, Int) -> Int32) -> String {
        // Call 1: size query (nil buffer).
        let needed = f(nil, 0)
        guard needed > 0 else { return "" }
        // Call 2: fill the exactly-sized buffer; decode as NUL-terminated.
        var buf = [CChar](repeating: 0, count: Int(needed))
        _ = buf.withUnsafeMutableBufferPointer { f($0.baseAddress, $0.count) }
        return String(cString: buf)
    }
}
