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

    func startScan(path: String, volume: VolumeInfo?) {
        let volume = volume ?? VolumeInfo.containing(path: path)
        do {
            let scan = try EngineScan(root: path) { [weak self] progress in
                Task { @MainActor in self?.applyProgress(progress) }
            }
            self.scan = scan
            self.model = scan.model
            self.volumeForScan = volume
            if let volume {
                scan.model.setVolumeFigures(total: volume.total, free: volume.free)
            }
            scanTargetPath = path
            rootName = volume?.url.path == path ? (volume?.name ?? path) : (path as NSString).lastPathComponent
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
        if cleanup.toggle(node: node, model: model) == .refusedSystemCritical {
            lastError = "System-critical paths can’t be staged for cleanup."
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
        let isExpanded = expanded.contains(node)
        out.append(
            Row(
                node: node,
                depth: depth,
                name: model.name(of: node),
                size: info.logical,
                percentOfRoot: model.percentOfRoot(node),
                category: info.category,
                isDirectory: info.isDirectory,
                hasChildren: info.childCount > 0,
                isExpanded: isExpanded))
        guard isExpanded, depth < 24 else { return }
        let children = model.children(of: node, sort: .size, descending: true)
        for child in children.prefix(Self.perLevelLimit) {
            appendRows(node: child, depth: depth + 1, model: model, into: &out)
        }
        if node == model.root, children.count > Self.perLevelLimit {
            let tail = children.dropFirst(Self.perLevelLimit)
            let bytes = tail.reduce(UInt64(0)) { acc, id in
                acc + ((try? model.info(id))?.logical ?? 0)
            }
            rootTail = TailSummary(count: tail.count, bytes: bytes)
        } else if node == model.root {
            rootTail = nil
        }
    }
}
