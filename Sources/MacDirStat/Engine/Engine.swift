import CDirstatCore
import Foundation

/// Swift wrapper for the dirstat-core C ABI (APP-FFI-1). This file is the
/// only place raw pointers appear; the rest of the app sees idiomatic
/// Swift types and opaque `NodeID` handles (APP-FFI-2).
enum Engine {
    /// Header/library version pin (APP-FFI-6): refuse to run against a
    /// mismatched pair. `DS_ABI_VERSION` comes from the checked-in header;
    /// `ds_abi_version()` from the linked library.
    static func verifyABI() {
        let linked = ds_abi_version()
        precondition(
            linked == UInt32(DS_ABI_VERSION),
            "dirstat-core ABI mismatch: header \(DS_ABI_VERSION), library \(linked). Rebuild the engine (make engine)."
        )
    }

    /// Engine errors surface as Swift errors with detail (APP-FFI-5).
    static func lastError() -> String {
        let needed = ds_last_error(nil, 0)
        guard needed > 0 else { return "unknown engine error" }
        var buf = [CChar](repeating: 0, count: Int(needed))
        _ = ds_last_error(&buf, buf.count)
        return String(cString: buf)
    }
}

struct EngineError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
    static func fromEngine() -> EngineError { EngineError(message: Engine.lastError()) }
}

/// Opaque node handle. Valid for the life of its `EngineModel` (APP-FFI-4).
struct NodeID: Hashable {
    let raw: UInt64
    static let invalid = NodeID(raw: 0)
    var isValid: Bool { raw != 0 }
}

/// Kind categories (engine `Category`, design 1g). RGB lives app-side.
enum KindCategory: UInt8, CaseIterable, Identifiable {
    case developer = 0, media, photos, documents, archives, system, apps, other
    var id: UInt8 { rawValue }

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

struct NodeInfo {
    let id: NodeID
    let parent: NodeID
    let logical: UInt64
    let physical: UInt64
    let files: UInt64
    let subdirs: UInt64
    let items: UInt64
    let mtime: Date?
    let childCount: Int
    let isDirectory: Bool
    let isSymlink: Bool
    let isUnreadable: Bool
    let category: KindCategory
    let ageBucket: Int
    let extSlot: Int

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
        category = KindCategory(rawValue: c.category) ?? .other
        ageBucket = Int(c.age_bucket)
        extSlot = Int(c.ext_slot)
    }
}

struct TreemapRect {
    let node: NodeID
    let x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat
    let depth: Int
    let isDir: Bool
    let category: KindCategory
    let ageBucket: Int
    let extSlot: Int
    var frame: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct TypeStat: Identifiable {
    let ext: String
    let logical: UInt64
    let files: UInt64
    /// 0..11 distinct palette slot, 12 = "other".
    let slot: Int
    var id: String { ext }
}

struct CategoryStat: Identifiable {
    let category: KindCategory
    let logical: UInt64
    let files: UInt64
    var id: UInt8 { category.rawValue }
}

struct VolumeReconciliation {
    let total: UInt64
    let free: UInt64
    /// The "N GB unreadable" number: capacity − free − measured, engine math.
    let unknown: UInt64
}

enum ChildSort: UInt8 {
    case size = 0, name = 1, items = 2, mtime = 3
}

enum TreemapAlgorithm: UInt8 {
    case kdirstat = 0
    case squarified = 1
}

/// Progress snapshot, already hopped to the main actor (APP-FFI-3).
struct ScanProgress {
    let items: UInt64
    let bytes: UInt64
    let currentPath: String
    let done: Bool
}

private final class ProgressBox {
    let handler: @Sendable (ScanProgress) -> Void
    init(_ handler: @escaping @Sendable (ScanProgress) -> Void) { self.handler = handler }
}

/// A running scan. Owns the engine scan handle; `model` is safe to read
/// progressively while scanning (the engine's numbers only grow — the
/// contract behind design 1d).
final class EngineScan {
    private let handle: OpaquePointer
    let model: EngineModel
    private let progressBox: ProgressBox?

    /// Progress callbacks arrive on engine threads; the wrapper marshals
    /// them to the main queue before they reach app state (APP-FFI-3).
    init(root: String, onProgress: @escaping @Sendable (ScanProgress) -> Void) throws {
        Engine.verifyABI()
        let box = ProgressBox { progress in
            DispatchQueue.main.async { onProgress(progress) }
        }
        let user = Unmanaged.passUnretained(box).toOpaque()
        let callback: @convention(c) (
            UInt64, UInt64, UnsafePointer<CChar>?, UInt8, UnsafeMutableRawPointer?
        ) -> Void = { items, bytes, path, done, user in
            guard let user else { return }
            let box = Unmanaged<ProgressBox>.fromOpaque(user).takeUnretainedValue()
            let pathString = path.map { String(cString: $0) } ?? ""
            box.handler(
                ScanProgress(items: items, bytes: bytes, currentPath: pathString, done: done == 1))
        }
        guard let handle = root.withCString({ ds_scan_begin($0, nil, callback, user) }) else {
            throw EngineError.fromEngine()
        }
        guard let modelPtr = ds_scan_model(handle) else {
            ds_scan_free(handle)
            throw EngineError.fromEngine()
        }
        self.handle = handle
        self.progressBox = box
        self.model = EngineModel(taking: modelPtr)
    }

    var isComplete: Bool { ds_scan_is_complete(handle) == 1 }

    /// Stop keeps everything found so far (design 1d).
    func cancel() { ds_scan_cancel(handle) }

    deinit {
        ds_scan_cancel(handle)
        ds_scan_join(handle)
        ds_scan_free(handle)
    }
}

/// A scanned model. The engine owns the tree; this class owns the model
/// lifetime and frees it deterministically (APP-FFI-4).
final class EngineModel {
    private let ptr: OpaquePointer

    fileprivate init(taking ptr: OpaquePointer) {
        self.ptr = ptr
    }

    deinit { ds_model_free(ptr) }

    var root: NodeID { NodeID(raw: ds_model_root(ptr)) }

    var stats: (items: UInt64, bytes: UInt64, complete: Bool, errorCount: UInt64) {
        var s = DsScanStats()
        _ = ds_model_stats(ptr, &s)
        return (s.items, s.bytes, s.complete == 1, s.error_count)
    }

    func info(_ id: NodeID) throws -> NodeInfo {
        var c = DsNodeInfo()
        guard ds_node_info(ptr, id.raw, &c) == 0 else { throw EngineError.fromEngine() }
        return NodeInfo(c)
    }

    func name(of id: NodeID) -> String {
        stringCall { ds_node_name(ptr, id.raw, $0, $1) }
    }

    func path(of id: NodeID) -> String {
        stringCall { ds_node_path(ptr, id.raw, $0, $1) }
    }

    /// Sorted child enumeration — sorting happens in the engine
    /// (within-parent only, stable), the app just renders (APP-DIR-2).
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

    func percentOfRoot(_ id: NodeID) -> Double { ds_node_percent_of_root(ptr, id.raw) }

    /// Full extension table (the ⌘T popover, design 1b).
    func typeList(max: Int = 512) -> [TypeStat] {
        var buf = [DsTypeStat](repeating: DsTypeStat(), count: max)
        let total = buf.withUnsafeMutableBufferPointer {
            ds_type_list(ptr, $0.baseAddress, $0.count)
        }
        guard total > 0 else { return [] }
        return buf.prefix(min(Int(total), max)).map { c in
            var extBytes = c.ext
            let ext = withUnsafeBytes(of: &extBytes) { raw -> String in
                let data = raw.prefix(while: { $0 != 0 })
                return String(decoding: data, as: UTF8.self)
            }
            return TypeStat(ext: ext, logical: c.logical, files: c.files, slot: Int(c.slot))
        }
    }

    /// Per-category totals for the legend chips + capacity footer (1b).
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
                files: $0.files)
        }
    }

    /// Host supplies capacity/free (APP-TARGET-3); engine owns the
    /// `<Unknown>` reconciliation math.
    func setVolumeFigures(total: UInt64, free: UInt64) {
        _ = ds_model_set_volume(ptr, total, free)
    }

    var volumeReconciliation: VolumeReconciliation? {
        var v = DsVolumeInfo()
        guard ds_model_volume(ptr, &v) == 0 else { return nil }
        return VolumeReconciliation(total: v.total, free: v.free, unknown: v.unknown)
    }

    var scanReport: [String] {
        let count = stats.errorCount
        return (0..<min(count, 500)).map { i in
            stringCall { ds_model_error(ptr, i, $0, $1) }
        }
    }

    /// One bulk buffer per (re)layout (APP-FFI-2 / CORE-FFI-6), converted
    /// to Swift values and freed before returning.
    func treemapLayout(
        root: NodeID, width: CGFloat, height: CGFloat,
        algorithm: TreemapAlgorithm = .squarified, minPixel: CGFloat = 2
    ) -> [TreemapRect] {
        var rects: UnsafeMutablePointer<DsTmRect>?
        var count = 0
        guard
            ds_treemap_layout(
                ptr, root.raw, Float(width), Float(height), algorithm.rawValue,
                Float(minPixel), &rects, &count) == 0, let rects
        else { return [] }
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
    func pathToRoot(_ id: NodeID) -> [NodeID] {
        var chain: [NodeID] = []
        var cur = id
        while cur.isValid, let nodeInfo = try? self.info(cur) {
            chain.append(cur)
            cur = nodeInfo.parent
        }
        return chain.reversed()
    }

    private func stringCall(_ f: (UnsafeMutablePointer<CChar>?, Int) -> Int32) -> String {
        let needed = f(nil, 0)
        guard needed > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: Int(needed))
        _ = buf.withUnsafeMutableBufferPointer { f($0.baseAddress, $0.count) }
        return String(cString: buf)
    }
}
