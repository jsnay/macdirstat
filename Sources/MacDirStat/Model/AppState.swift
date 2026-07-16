import AppKit
import Combine
import SwiftUI

/// Central app state. The window is the picker (1f) until a scan starts;
/// during a scan the same main surface is live (1d); afterwards it is the
/// evolved two-pane layout (1b).
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case welcome
        case active  // scanning or ready; `isScanning` distinguishes
    }

    @Published private(set) var phase: Phase = .welcome
    @Published private(set) var isScanning = false

    private(set) var scan: EngineScan?
    private(set) var model: EngineModel?

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
    @Published private(set) var layoutGeneration: Int = 0

    // View state (1b).
    @Published var selection: NodeID?
    @Published var colorMode: ColorMode = .kind
    /// On-disk (allocated) sizes by default: cloud placeholders and clones
    /// make logical sizes exceed the physical disk. Toggle in the View menu.
    @Published var sizeMetric: SizeMetric = .physical {
        didSet {
            guard sizeMetric != oldValue else { return }
            outline.metric = sizeMetric
            outline.reload()
            layoutGeneration += 1
        }
    }
    @Published var isolatedCategory: KindCategory?  // legend chip click-to-isolate
    @Published var searchText: String = ""
    @Published var typeTablePresented = false

    /// Zoom/re-root stack; back/forward chevrons in the 1b toolbar.
    @Published private(set) var zoomRoot: NodeID?
    private var zoomBack: [NodeID] = []
    private var zoomForward: [NodeID] = []

    @Published private(set) var categories: [CategoryStat] = []
    @Published private(set) var reconciliation: VolumeReconciliation?
    @Published private(set) var rootName: String = ""
    @Published private(set) var scanTargetPath: String = ""
    @Published var lastError: String?
    /// A subtree re-scan ("Re-scan From Here") is in flight.
    @Published private(set) var isRefreshing = false
    /// What the user originally asked to scan, for Re-scan All.
    private var lastRequest: (path: String, volume: VolumeInfo?)?

    let cleanup = CleanupStore()
    let outline = OutlineStore()

    private var settleTimer: Timer?
    private var volumeForScan: VolumeInfo?

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

    func startScan(path: String, volume: VolumeInfo?) {
        let volume = volume ?? VolumeInfo.containing(path: path)
        lastRequest = (path, volume)
        // Scanning "Macintosh HD" means scanning the APFS Data volume: all
        // user data, one device, and no firmlink double-traversal (the bug
        // that made a 256 GB disk read as a terabyte).
        var target = path
        if path == "/", let volume, volume.url.path == "/" {
            target = volume.scanPath
        }
        do {
            let scan = try EngineScan(root: target, skipPaths: Self.systemSkipPaths) {
                [weak self] progress in
                Task { @MainActor in self?.applyProgress(progress) }
            }
            self.scan = scan
            self.model = scan.model
            self.volumeForScan = volume
            if let volume {
                scan.model.setVolumeFigures(total: volume.total, free: volume.free)
            }
            scanTargetPath = target
            rootName =
                volume?.url.path == path
                ? (volume?.name ?? path) : (path as NSString).lastPathComponent
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

    /// Stop keeps everything found so far (1d).
    func stopScan() {
        scan?.cancel()
    }

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

    private func applyProgress(_ p: ScanProgress) {
        // Monotonic by engine contract; max() guards out-of-order delivery.
        progressItems = max(progressItems, p.items)
        progressBytes = max(progressBytes, p.bytes)
        progressPath = p.currentPath
        if let used = volumeForScan.map({ Double($0.used) }), used > 0 {
            progressFraction = min(1.0, Double(progressBytes) / used)
        }
        if p.done {
            finishScan()
        }
    }

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

    func refreshAggregates() {
        guard let model else { return }
        categories = model.categoryList()
        reconciliation = model.volumeReconciliation
    }

    /// Called after cleanup commits so every pane reconciles (1e).
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
    func select(node: NodeID, revealInOutline: Bool) {
        selection = node
        if revealInOutline, let model {
            outline.reveal(path: model.pathToRoot(node))
        }
    }

    // MARK: - Zoom / re-root

    func zoomInto(_ node: NodeID) {
        guard let model, node.isValid else { return }
        guard (try? model.info(node))?.isDirectory == true else { return }
        zoomBack.append(treemapRoot)
        zoomForward = []
        zoomRoot = node
        layoutGeneration += 1
    }

    func goBack() {
        guard let previous = zoomBack.popLast() else { return }
        zoomForward.append(treemapRoot)
        zoomRoot = previous == model?.root ? nil : previous
        layoutGeneration += 1
    }

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
        Task.detached { [model] in
            let failure: String?
            do {
                try model.refresh(node)
                failure = nil
            } catch {
                failure = "\(error)"
            }
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

    // MARK: - Actions

    func revealInFinder(_ node: NodeID) {
        guard let model else { return }
        let url = URL(fileURLWithPath: model.path(of: node))
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyPath(_ node: NodeID) {
        guard let model else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.path(of: node), forType: .string)
    }

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

    func commitCleanup() async {
        guard let model else { return }
        let failures = await cleanup.commitToTrash(model: model)
        if !failures.isEmpty {
            lastError = "Some items couldn’t be trashed:\n" + failures.joined(separator: "\n")
        }
        modelDidMutate()
    }
}

/// Lazily-expanded outline rows for the 1b sidebar ("Largest first"): one
/// smart column, engine-sorted, fetched per visible level only.
@MainActor
final class OutlineStore: ObservableObject {
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

    @Published private(set) var rows: [Row] = []
    private var expanded: Set<NodeID> = []
    private var model: EngineModel?
    /// Which byte count the rows display/sort by (set by AppState).
    var metric: SizeMetric = .physical

    /// Cap children shown per level; the tail collapses into a summary row
    /// (the design's "…and 11 more, 64.1 GB").
    static let perLevelLimit = 14

    struct TailSummary: Equatable {
        let count: Int
        let bytes: UInt64
    }
    @Published private(set) var rootTail: TailSummary?

    func attach(model: EngineModel) {
        self.model = model
        expanded = []
        if model.root.isValid { expanded.insert(model.root) }
        reload()
    }

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

    func parent(of node: NodeID) -> NodeID? {
        guard let model, let info = try? model.info(node), info.parent.isValid else {
            return nil
        }
        return info.parent
    }

    func reveal(path: [NodeID]) {
        for ancestor in path.dropLast() {
            expanded.insert(ancestor)
        }
        reload()
    }

    func reload() {
        guard let model, model.root.isValid else {
            rows = []
            return
        }
        var out: [Row] = []
        appendRows(node: model.root, depth: 0, model: model, into: &out)
        rows = out
    }

    private func appendRows(node: NodeID, depth: Int, model: EngineModel, into out: inout [Row]) {
        guard let info = try? model.info(node) else { return }
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
        let sort: ChildSort = metric == .physical ? .physicalSize : .size
        let children = model.children(of: node, sort: sort, descending: true)
        for child in children.prefix(Self.perLevelLimit) {
            appendRows(node: child, depth: depth + 1, model: model, into: &out)
        }
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

    private func bytes(of info: NodeInfo) -> UInt64 {
        metric == .physical ? info.physical : info.logical
    }
}
