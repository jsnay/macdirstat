import AppKit
import Combine
import SwiftUI

// =============================================================================
// FILE: Sources/MacDirStat/Model/AppState.swift
// =============================================================================
//
// PURPOSE
//   The app's central, main-actor state machine and the single owner of the
//   engine objects. It drives the whole window lifecycle — welcome picker
//   (1f) to live progressive scan (1d) to the ready two-pane layout (1b) —
//   and embodies the key 1d decision: the UI is fully usable DURING a scan,
//   with the treemap re-laying out on a ~2s settle cadence rather than per
//   file. Also hosts OutlineStore, the lazily-expanded sidebar row model.
//
// UPSTREAM DEPENDENCIES (what this file consumes)
//   - Engine/Engine.swift: EngineScan (scan lifecycle + progress),
//     EngineModel (all reads/refresh), NodeID (selection/zoom), ScanProgress,
//     SizeMetric/ChildSort, CategoryStat/VolumeReconciliation aggregates.
//   - Model/CleanupStore.swift: owned `cleanup` store; toggle/commit are
//     funnelled through here so errors surface in the shared alert.
//   - Model/Volumes.swift: VolumeInfo (capacity figures + the Data-volume
//     scanPath decision), RecentScans (welcome chips).
//   - Model/Palette.swift: ColorMode (the published 1g channel selection).
//   - SwiftUI/Combine: ObservableObject + @Published; AppKit: NSWorkspace /
//     NSPasteboard for Reveal in Finder / Copy Path.
//
// DOWNSTREAM CONSUMERS (who depends on this file)
//   - MacDirStatApp.swift: creates the one AppState, injects it as an
//     @EnvironmentObject; menu commands call startScan/rescan/goBack/etc.
//   - Views/MainView.swift: toolbar (progress cluster, color picker),
//     legend chips (categories/isolatedCategory), footer (reconciliation).
//   - Views/TreemapPane.swift: layoutGeneration, treemapRoot, selection,
//     progressFraction, select/zoomInto.
//   - Views/SidebarOutline.swift: outline store, selection, searchText.
//   - Views/WelcomeView.swift: startScan entry point.
//   - Views/CleanupReviewSheet.swift / TypeTableSheet.swift: commitCleanup,
//     model reads.
//
// STRUCTURE
//   - AppState: phases + scan lifecycle + progress + settle cadence +
//     selection/zoom stacks + size metric + actions (Finder/clipboard/
//     cleanup/rescan)
//   - OutlineStore: lazily-expanded sidebar rows with per-level cap + tail
//     summary
//
// BEHAVIOR & INVARIANTS
//   - Everything here is @MainActor; engine progress callbacks arrive
//     already marshalled to the main queue (APP-FFI-3), and applyProgress
//     re-hops via Task at the actor boundary.
//   - Progress counters are monotonic: applyProgress max()-guards them, so
//     the 1d promise "sizes only grow" holds even under reordered delivery.
//   - layoutGeneration is the relayout contract: the treemap re-requests
//     engine geometry ONLY when this integer changes (settle timer tick,
//     scan finish, zoom change, metric change, model mutation) — never on
//     ordinary @Published churn. That is what stops per-file shimmering.
//   - Observation topology: AppState, OutlineStore, and CleanupStore are
//     three separate ObservableObjects. Nested objects do NOT republish
//     through @EnvironmentObject, so views observe outline/cleanup
//     explicitly via @ObservedObject where they need their updates.
// =============================================================================

/// Central app state. The window is the picker (1f) until a scan starts;
/// during a scan the same main surface is live (1d); afterwards it is the
/// evolved two-pane layout (1b).
@MainActor
final class AppState: ObservableObject {
    // MARK: - Phase & engine handles

    /// The two window surfaces. There is deliberately no separate
    /// "scanning" phase: scanning and ready are the SAME layout (1d), so
    /// `.active` covers both and `isScanning` distinguishes them.
    enum Phase: Equatable {
        case welcome
        case active  // scanning or ready; `isScanning` distinguishes
    }

    @Published private(set) var phase: Phase = .welcome
    /// True from startScan until the engine's done callback (or Stop).
    @Published private(set) var isScanning = false

    /// The running scan, if any. Dropping it triggers EngineScan.deinit
    /// (cancel + join + free) — how backToPicker tears a scan down.
    private(set) var scan: EngineScan?
    /// The current model. Intentionally NOT @Published: model content
    /// changes are communicated via layoutGeneration / refreshAggregates,
    /// not by identity churn.
    private(set) var model: EngineModel?

    // MARK: - Scan progress (1d)

    // Scan progress (1d): counters appear immediately and only go up.
    @Published private(set) var progressItems: UInt64 = 0
    @Published private(set) var progressBytes: UInt64 = 0
    @Published private(set) var progressPath: String = ""
    /// Determinate: bytes counted vs used-bytes on the volume — the
    /// denominator is known before the scan starts (1d).
    @Published private(set) var progressFraction: Double = 0

    /// Bumped on the ~2s settle cadence during a scan, and on selection-
    /// relevant model mutations after it; the treemap re-layouts only when
    /// this changes (1d: "layout reflows on a cadence, not per file").
    ///
    /// This is a one-way CONTRACT with TreemapPane: engine layout is
    /// comparatively expensive and visually disruptive, so views must
    /// never re-request geometry on ordinary state churn — only on a
    /// generation bump (or a pane resize). Bumped by: settle timer tick,
    /// finishScan, zoom/back/forward, sizeMetric change, modelDidMutate.
    @Published private(set) var layoutGeneration: Int = 0

    // MARK: - View state (1b)

    /// The single shared selection (APP-COUPLE-4): sidebar row and treemap
    /// ring always show this same node.
    @Published var selection: NodeID?
    /// Which 1g color channel the treemap uses (kind / age / extension).
    @Published var colorMode: ColorMode = .kind
    /// On-disk (allocated) sizes by default: cloud placeholders and clones
    /// make logical sizes exceed the physical disk. Toggle in the View menu.
    /// Changing it re-sorts the outline and forces a treemap relayout —
    /// both panes must agree on the metric or areas contradict row sizes.
    @Published var sizeMetric: SizeMetric = .physical {
        didSet {
            guard sizeMetric != oldValue else { return }
            outline.metric = sizeMetric
            outline.reload()
            layoutGeneration += 1
        }
    }
    @Published var isolatedCategory: KindCategory?  // legend chip click-to-isolate
    /// Sidebar filter text (toolbar search field).
    @Published var searchText: String = ""
    /// Presents the ⌘T full extension table sheet.
    @Published var typeTablePresented = false

    /// Zoom/re-root stack; back/forward chevrons in the 1b toolbar.
    /// nil means "not zoomed" (treemap shows the model root). The two
    /// private stacks give browser-style history: zoomInto pushes the
    /// current root onto `zoomBack` and clears `zoomForward`; goBack /
    /// goForward shuttle roots between the stacks.
    @Published private(set) var zoomRoot: NodeID?
    private var zoomBack: [NodeID] = []
    private var zoomForward: [NodeID] = []

    /// Per-kind totals for the legend chips; refreshed on the settle
    /// cadence and after mutations (never per progress callback).
    @Published private(set) var categories: [CategoryStat] = []
    /// Engine capacity math for the footer bar; nil before figures exist.
    @Published private(set) var reconciliation: VolumeReconciliation?
    /// Toolbar title: the volume name, or the folder's last component.
    @Published private(set) var rootName: String = ""
    /// The path actually handed to the engine (may differ from what the
    /// user picked — see the Data-volume redirect in startScan).
    @Published private(set) var scanTargetPath: String = ""
    /// One-shot error surface; RootView shows it as the app-wide alert.
    @Published var lastError: String?
    /// A subtree re-scan ("Re-scan From Here") is in flight.
    @Published private(set) var isRefreshing = false
    /// What the user originally asked to scan, for Re-scan All.
    private var lastRequest: (path: String, volume: VolumeInfo?)?

    /// Child stores. Separate ObservableObjects on purpose: their updates
    /// do NOT propagate through AppState's objectWillChange, so views that
    /// need them observe them directly (see the file header's observation
    /// topology note and MainView's explicit @ObservedObject wrappers).
    let cleanup = CleanupStore()
    let outline = OutlineStore()

    /// Drives the ~2s settle cadence while scanning (see startSettleCadence).
    private var settleTimer: Timer?
    /// Capacity figures of the volume being scanned — the denominator of
    /// the determinate progress bar (1d).
    private var volumeForScan: VolumeInfo?

    /// What the treemap should lay out: the zoom root if zoomed, else the
    /// model root, else invalid (renders nothing).
    var treemapRoot: NodeID {
        zoomRoot ?? model?.root ?? .invalid
    }

    var canGoBack: Bool { !zoomBack.isEmpty }
    var canGoForward: Bool { !zoomForward.isEmpty }

    // MARK: - Scan lifecycle

    /// Directories the engine must never descend into. Exact-path matches,
    /// so these only bite when scanning `/` on an older macOS layout; the
    /// normal boot-volume path scans `/System/Volumes/Data` directly. The
    /// engine additionally dedupes aliased directory inodes (firmlinks,
    /// bind mounts) as defense in depth.
    static let systemSkipPaths = [
        "/System/Volumes/Data", "/System/Volumes/VM", "/System/Volumes/Preboot",
        "/System/Volumes/Update", "/System/Volumes/Hardware", "/System/Volumes/iSCPreboot",
        "/System/Volumes/xarts", "/Volumes", "/dev",
    ]

    /// Begin a scan and switch the window to the active surface. The state
    /// machine's welcome→scanning edge; also the "ready→scanning" edge for
    /// Re-scan All (a fresh scan simply replaces the old scan + model).
    ///
    /// - Parameters:
    ///   - path: what the user asked to scan (volume mount point or folder).
    ///   - volume: capacity figures if the caller already has them; looked
    ///     up from the containing volume otherwise (drop/recent targets).
    func startScan(path: String, volume: VolumeInfo?) {
        let volume = volume ?? VolumeInfo.containing(path: path)
        lastRequest = (path, volume)
        // Scanning "Macintosh HD" means scanning the APFS Data volume: all
        // user data, one device, and no firmlink double-traversal (the bug
        // that made a 256 GB disk read as a terabyte).
        //
        // Background: since Catalina, "/" is a sealed read-only System
        // volume plus a writable Data volume mounted at
        // /System/Volumes/Data, stitched together with firmlinks (/Users,
        // /Applications, ...). Walking "/" naively visits every firmlinked
        // tree twice — once at its "/" alias and once under the Data mount.
        // Scanning the Data volume directly counts everything exactly once;
        // the sealed System volume's few GB show up via the capacity
        // reconciliation instead (see VolumeInfo.scanPath).
        var target = path
        if path == "/", let volume, volume.url.path == "/" {
            target = volume.scanPath
        }
        do {
            // The progress closure is @Sendable and already main-queue
            // (Engine marshals it); the extra Task @MainActor hop is what
            // lets the compiler prove the call into this actor is safe.
            let scan = try EngineScan(root: target, skipPaths: Self.systemSkipPaths) {
                [weak self] progress in
                Task { @MainActor in self?.applyProgress(progress) }
            }
            // Replacing `scan`/`model` releases any previous pair; the old
            // EngineScan deinit cancels + joins its threads (APP-FFI-4).
            self.scan = scan
            self.model = scan.model
            self.volumeForScan = volume
            // Hand macOS's capacity figures to the engine so it can do the
            // free/unknown reconciliation math (APP-TARGET-3).
            if let volume {
                scan.model.setVolumeFigures(total: volume.total, free: volume.free)
            }
            scanTargetPath = target
            rootName =
                volume?.url.path == path
                ? (volume?.name ?? path) : (path as NSString).lastPathComponent
            // Reset every piece of per-scan view state: old NodeIDs belong
            // to the replaced model and must not survive (APP-FFI-4).
            phase = .active
            isScanning = true
            progressItems = 0
            progressBytes = 0
            progressFraction = 0
            selection = nil
            zoomRoot = nil
            zoomBack = []
            zoomForward = []
            isolatedCategory = nil
            cleanup.clear()
            outline.metric = sizeMetric
            outline.attach(model: scan.model)
            RecentScans.record(path)
            startSettleCadence()
        } catch {
            lastError = "\(error)"
        }
    }

    /// Stop keeps everything found so far (1d). Cancellation is async: the
    /// engine's final done=true callback flows through applyProgress →
    /// finishScan, which is what flips `isScanning` off.
    func stopScan() {
        scan?.cancel()
    }

    /// The active→welcome edge: tear everything down and show the picker.
    /// Dropping `scan` runs EngineScan.deinit (cancel + join + free);
    /// dropping `model` frees the engine model once views release it.
    func backToPicker() {
        scan?.cancel()
        settleTimer?.invalidate()
        settleTimer = nil
        scan = nil
        model = nil
        phase = .welcome
        isScanning = false
        selection = nil
        cleanup.clear()
    }

    /// Apply one progress callback (already on the main actor, APP-FFI-3).
    /// Only the cheap counters update here; aggregates and layout wait for
    /// the settle cadence — this fires far too often to touch them.
    private func applyProgress(_ p: ScanProgress) {
        // Monotonic by engine contract; max() guards out-of-order delivery.
        // The 1d sidebar note "Sizes only grow" is this line's promise.
        progressItems = max(progressItems, p.items)
        progressBytes = max(progressBytes, p.bytes)
        progressPath = p.currentPath
        // Determinate fraction: used-bytes on the volume is known up front,
        // so bytes-counted / bytes-used is a real denominator (1d).
        if let used = volumeForScan.map({ Double($0.used) }), used > 0 {
            progressFraction = min(1.0, Double(progressBytes) / used)
        }
        if p.done {
            finishScan()
        }
    }

    /// The scanning→ready edge (also reached via Stop): kill the cadence
    /// timer, snap progress to full, and do one final aggregate + layout +
    /// outline pass so the settled UI reflects the complete model.
    private func finishScan() {
        isScanning = false
        settleTimer?.invalidate()
        settleTimer = nil
        progressFraction = 1
        refreshAggregates()
        layoutGeneration += 1
        outline.reload()
    }

    /// The ~2s settle cadence (1d): the map subdivides on a timer, not per
    /// file, so it grows without shimmering.
    ///
    /// Each tick does the full "settle" — re-read aggregates, bump
    /// layoutGeneration (the only thing that makes the treemap re-request
    /// geometry), and rebuild outline rows. One immediate settle runs
    /// before the timer starts so the UI isn't empty for the first 2s.
    /// Timer callbacks are not actor-isolated, hence the Task @MainActor
    /// hop; the isScanning guard makes a straggler tick after finishScan
    /// harmless.
    private func startSettleCadence() {
        settleTimer?.invalidate()
        refreshAggregates()
        layoutGeneration += 1
        settleTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isScanning else { return }
                self.refreshAggregates()
                self.layoutGeneration += 1
                self.outline.reload()
            }
        }
    }

    /// Re-pull the derived aggregates (legend chips, capacity footer) from
    /// the engine. Cheap enough for every settle tick.
    func refreshAggregates() {
        guard let model else { return }
        categories = model.categoryList()
        reconciliation = model.volumeReconciliation
    }

    /// Called after cleanup commits so every pane reconciles (1e).
    /// Also drops a selection whose node no longer exists (trashed) —
    /// `info` failing is the "node vanished" signal.
    func modelDidMutate() {
        refreshAggregates()
        layoutGeneration += 1
        outline.reload()
        if let selection, (try? model?.info(selection)) == nil {
            self.selection = nil
        }
    }

    // MARK: - Selection coupling (APP-COUPLE-*)

    /// Treemap click → select → sidebar expands to and reveals the node.
    /// `revealInOutline` is true only for map-originated selections; a
    /// sidebar click passes false (the row is already visible, and
    /// re-expanding would fight the user's own folding).
    func select(node: NodeID, revealInOutline: Bool) {
        selection = node
        if revealInOutline, let model {
            outline.reveal(path: model.pathToRoot(node))
        }
    }

    // MARK: - Zoom / re-root

    /// Re-root the treemap on a directory (double-click / context menu).
    /// Browser-history semantics: push the current root on the back stack
    /// and clear the forward stack, exactly like navigating a browser.
    func zoomInto(_ node: NodeID) {
        guard let model, node.isValid else { return }
        // Only directories can be roots; a file rect zooms via its parent.
        guard (try? model.info(node))?.isDirectory == true else { return }
        zoomBack.append(treemapRoot)
        zoomForward = []
        zoomRoot = node
        layoutGeneration += 1
    }

    /// Zoom out one step (⌘[). Popping back pushes the current root onto
    /// the forward stack so goForward can retrace. Reaching the model root
    /// stores nil (the canonical "not zoomed" state) so treemapRoot keeps
    /// a single representation for it.
    func goBack() {
        guard let previous = zoomBack.popLast() else { return }
        zoomForward.append(treemapRoot)
        zoomRoot = previous == model?.root ? nil : previous
        layoutGeneration += 1
    }

    /// Re-descend along the forward stack (⌘]); mirror image of goBack.
    func goForward() {
        guard let next = zoomForward.popLast() else { return }
        zoomBack.append(treemapRoot)
        zoomRoot = next
        layoutGeneration += 1
    }

    // MARK: - Re-scan (for changes made outside the app)

    /// Re-read one node and its subtree from disk — "Re-scan From Here",
    /// for when the filesystem was changed in Finder or a terminal. Runs
    /// off the main thread (the engine allows concurrent reads); every
    /// pane reconciles when it lands.
    func rescan(_ node: NodeID) {
        guard let model, node.isValid, !isScanning, !isRefreshing else { return }
        isRefreshing = true
        // Detached: refresh walks the subtree on disk and may take a
        // while; EngineModel is (@unchecked) Sendable so handing it to a
        // background task is part of the engine's documented contract.
        Task.detached { [model] in
            let failure: String?
            do {
                try model.refresh(node)
                failure = nil
            } catch {
                failure = "\(error)"
            }
            // Hop back to the main actor to publish the result.
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isRefreshing = false
                if let failure { self.lastError = "Re-scan failed: \(failure)" }
                self.modelDidMutate()
            }
        }
    }

    /// Throw away the model and scan the original target again (⇧⌘R).
    func rescanAll() {
        guard let request = lastRequest, !isScanning else { return }
        startScan(path: request.path, volume: request.volume)
    }

    // MARK: - Actions (OS integration + cleanup funnel)

    /// Select the item in a Finder window (context menus, APP-ACT-4-ish).
    func revealInFinder(_ node: NodeID) {
        guard let model else { return }
        let url = URL(fileURLWithPath: model.path(of: node))
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Put the absolute path on the general pasteboard (APP-ACT-2).
    func copyPath(_ node: NodeID) {
        guard let model else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.path(of: node), forType: .string)
    }

    /// Stage/unstage a node for cleanup, translating the store's refusal
    /// cases into user-facing alert text (design 1e rule 4 surfaces here).
    func toggleCleanup(_ node: NodeID) {
        guard let model else { return }
        switch cleanup.toggle(node: node, model: model) {
        case .refusedSystemCritical:
            lastError = "System-critical paths can’t be staged for cleanup."
        case .failed:
            lastError = "Couldn’t read that item’s details — try rescanning."
        case .staged, .unstaged:
            break
        }
    }

    /// Commit the staged cleanup (review sheet's "Move to Trash"), then
    /// reconcile every pane. Partial failures collect into one alert.
    func commitCleanup() async {
        guard let model else { return }
        let failures = await cleanup.commitToTrash(model: model)
        if !failures.isEmpty {
            lastError = "Some items couldn’t be trashed:\n" + failures.joined(separator: "\n")
        }
        modelDidMutate()
    }
}

// MARK: - OutlineStore: sidebar rows

/// Lazily-expanded outline rows for the 1b sidebar ("Largest first"): one
/// smart column, engine-sorted, fetched per visible level only.
///
/// The store flattens the visible part of the tree into a plain `rows`
/// array (a List renders faster and simpler than a recursive outline).
/// "Lazy" means children are fetched from the engine only for EXPANDED
/// nodes, per reload — nothing is cached across reloads, because mid-scan
/// the numbers change under us anyway (APP-FFI-2's visible-rows-only rule).
@MainActor
final class OutlineStore: ObservableObject {
    /// One flattened, render-ready sidebar row: everything the row view
    /// needs, precomputed, so rendering does no engine calls.
    struct Row: Identifiable, Equatable {
        let node: NodeID
        let depth: Int
        let name: String
        let size: UInt64
        let percentOfRoot: Double
        let category: KindCategory
        let isDirectory: Bool
        let hasChildren: Bool
        let isExpanded: Bool
        var id: UInt64 { node.raw }
    }

    /// The flattened visible rows, in display order (depth-first).
    @Published private(set) var rows: [Row] = []
    /// Which nodes are expanded; the only persistent outline state.
    private var expanded: Set<NodeID> = []
    private var model: EngineModel?
    /// Which byte count the rows display/sort by (set by AppState).
    /// Plain var, not @Published — AppState always calls reload() after.
    var metric: SizeMetric = .physical

    /// Cap children shown per level; the tail collapses into a summary row
    /// (the design's "…and 11 more, 64.1 GB").
    static let perLevelLimit = 14

    /// The collapsed tail beyond `perLevelLimit` at the ROOT level only:
    /// how many rows were hidden and how many bytes they hold.
    struct TailSummary: Equatable {
        let count: Int
        let bytes: UInt64
    }
    @Published private(set) var rootTail: TailSummary?

    /// Bind to a (new) model: reset expansion to just the root and build
    /// the first row set. Called once per scan from AppState.startScan.
    func attach(model: EngineModel) {
        self.model = model
        expanded = []
        if model.root.isValid { expanded.insert(model.root) }
        reload()
    }

    /// Flip one node's expansion (disclosure-triangle click).
    func toggle(_ node: NodeID) {
        if expanded.contains(node) {
            expanded.remove(node)
        } else {
            expanded.insert(node)
        }
        reload()
    }

    func isExpanded(_ node: NodeID) -> Bool {
        expanded.contains(node)
    }

    /// Explicitly expand/collapse (the sidebar's arrow-key handlers).
    func setExpanded(_ node: NodeID, _ value: Bool) {
        if value {
            expanded.insert(node)
        } else {
            expanded.remove(node)
        }
        reload()
    }

    /// First (largest) child of an expanded row, for →-into navigation.
    func firstChild(of node: NodeID) -> NodeID? {
        guard let model else { return nil }
        let sort: ChildSort = metric == .physical ? .physicalSize : .size
        return model.children(of: node, sort: sort, descending: true).first
    }

    /// Parent handle for ←-navigation; nil at the root (or on a stale id).
    func parent(of node: NodeID) -> NodeID? {
        guard let model, let info = try? model.info(node), info.parent.isValid else {
            return nil
        }
        return info.parent
    }

    /// Expand every ANCESTOR of a node (dropLast excludes the node itself
    /// — revealing must not also expand the target) so a treemap-click
    /// selection becomes visible in the sidebar (APP-COUPLE-2).
    func reveal(path: [NodeID]) {
        for ancestor in path.dropLast() {
            expanded.insert(ancestor)
        }
        reload()
    }

    /// Rebuild the whole flattened row array from the engine. Called on
    /// every settle tick, expansion change, metric change, and mutation;
    /// cost is proportional to VISIBLE rows only (capped per level), so a
    /// full rebuild stays trivially cheap and needs no diffing.
    func reload() {
        guard let model, model.root.isValid else {
            rows = []
            return
        }
        var out: [Row] = []
        appendRows(node: model.root, depth: 0, model: model, into: &out)
        rows = out
    }

    /// Depth-first walk of the EXPANDED part of the tree, appending
    /// render-ready rows. Recursion is bounded three ways: only expanded
    /// nodes recurse, at most `perLevelLimit` children per level, and a
    /// depth ceiling of 24 as a guard against pathological trees.
    private func appendRows(node: NodeID, depth: Int, model: EngineModel, into out: inout [Row]) {
        guard let info = try? model.info(node) else { return }
        // Percent is computed against the metric-appropriate root total
        // (engine's percentOfRoot is metric-agnostic, so compute here:
        // the %-bar must agree with the sizes the row displays).
        let rootBytes = (try? model.info(model.root)).map(bytes(of:)) ?? 0
        let nodeBytes = bytes(of: info)
        let isExpanded = expanded.contains(node)
        out.append(
            Row(
                node: node,
                depth: depth,
                name: model.name(of: node),
                size: nodeBytes,
                percentOfRoot: rootBytes > 0 ? Double(nodeBytes) / Double(rootBytes) * 100 : 0,
                category: info.category,
                isDirectory: info.isDirectory,
                hasChildren: info.childCount > 0,
                isExpanded: isExpanded))
        guard isExpanded, depth < 24 else { return }
        // Engine-side sort, largest first, in the metric the rows display.
        let sort: ChildSort = metric == .physical ? .physicalSize : .size
        let children = model.children(of: node, sort: sort, descending: true)
        for child in children.prefix(Self.perLevelLimit) {
            appendRows(node: child, depth: depth + 1, model: model, into: &out)
        }
        // Root level only: collapse the overflow into the "…and N more,
        // X GB" footer instead of an endless list. The design accepts the
        // O(tail) info calls here because the root's child count is small.
        if node == model.root, children.count > Self.perLevelLimit {
            let tail = children.dropFirst(Self.perLevelLimit)
            let bytes = tail.reduce(UInt64(0)) { acc, id in
                acc + ((try? model.info(id)).map(self.bytes(of:)) ?? 0)
            }
            rootTail = TailSummary(count: tail.count, bytes: bytes)
        } else if node == model.root {
            rootTail = nil
        }
    }

    /// The metric-selected byte count (mirrors CategoryStat.bytes).
    private func bytes(of info: NodeInfo) -> UInt64 {
        metric == .physical ? info.physical : info.logical
    }
}
