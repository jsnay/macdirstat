import AppKit
import Combine
import Foundation

/// Cleanup staging (design 1e): deciding is separated from doing. Items
/// collect here with a running reclaim total; one review, one commit — to
/// Trash, always. "Delete Permanently" is deliberately not a button this
/// store offers.
@MainActor
final class CleanupStore: ObservableObject {
    struct StagedItem: Identifiable, Equatable {
        let node: NodeID
        let name: String
        let path: String
        let size: UInt64
        let category: KindCategory
        let hint: CleanupHint
        var id: UInt64 { node.raw }
    }

    @Published private(set) var items: [StagedItem] = []
    @Published var reviewPresented = false
    /// Set briefly after a commit so the UI can show the space returning.
    @Published private(set) var lastReclaimed: UInt64?

    var total: UInt64 { items.reduce(0) { $0 + $1.size } }
    var stagedNodes: Set<NodeID> { Set(items.map(\.node)) }

    enum StageResult: Equatable {
        case staged
        case unstaged
        case refusedSystemCritical
        case failed
    }

    /// Toggle a node in/out of the cleanup list. System-critical paths
    /// can't be staged at all (design 1e rule 4).
    func toggle(node: NodeID, model: EngineModel) -> StageResult {
        if let index = items.firstIndex(where: { $0.node == node }) {
            items.remove(at: index)
            return .unstaged
        }
        let path = model.path(of: node)
        guard !CleanupGuard.isSystemCritical(path: path) else {
            return .refusedSystemCritical
        }
        guard let info = try? model.info(node) else { return .failed }
        items.append(
            StagedItem(
                node: node,
                name: model.name(of: node),
                path: path,
                size: info.logical,
                category: info.category,
                hint: CleanupHint.forPath(path)))
        return .staged
    }

    func remove(_ item: StagedItem) {
        items.removeAll { $0.node == item.node }
    }

    func clear() {
        items = []
    }

    /// Commit: move every staged item to the Trash (never permanent —
    /// APP-ACT-6), then refresh each affected node in the engine so all
    /// panes reconcile (APP-ACT-12). Returns paths that failed.
    func commitToTrash(model: EngineModel) async -> [String] {
        var failures: [String] = []
        let reclaim = total
        for item in items {
            let url = URL(fileURLWithPath: item.path)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                try? model.refresh(item.node)
            } catch {
                failures.append("\(item.path): \(error.localizedDescription)")
            }
        }
        items = []
        reviewPresented = false
        if failures.isEmpty {
            lastReclaimed = reclaim
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.lastReclaimed = nil
            }
        }
        return failures
    }
}

/// Path-aware safety rails (design 1e): block the paths where deletion is
/// never what the user means.
enum CleanupGuard {
    /// Prefixes that can never be staged. Children of some of them are
    /// fine (~/Library/Caches is a classic cleanup target); it's the roots
    /// and OS directories that are off-limits.
    static let forbiddenExact: Set<String> = [
        "/", "/System", "/Library", "/Applications", "/Users", "/usr", "/bin",
        "/sbin", "/etc", "/var", "/private", "/private/var", "/private/etc",
        "/opt", "/Volumes", "/cores", "/dev",
    ]

    static let forbiddenPrefixes: [String] = [
        "/System/", "/usr/", "/bin/", "/sbin/", "/private/etc/",
    ]

    /// The APFS Data volume re-exposes the user's world under
    /// `/System/Volumes/Data/...`; judge those paths by their canonical
    /// firmlinked location (`/Users/...`), or every real file would be
    /// refused by the `/System/` rule.
    static func canonicalize(_ path: String) -> String {
        let dataPrefix = "/System/Volumes/Data"
        if path == dataPrefix { return "/" }
        if path.hasPrefix(dataPrefix + "/") {
            return String(path.dropFirst(dataPrefix.count))
        }
        return path
    }

    static func isSystemCritical(path: String) -> Bool {
        let path = canonicalize(path)
        let clean = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        if forbiddenExact.contains(clean) { return true }
        if forbiddenPrefixes.contains(where: { clean.hasPrefix($0) }) { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if clean == home { return true }
        // The user's top-level standard folders (~/Documents itself, not
        // things inside it).
        let standardChildren = [
            "Documents", "Desktop", "Downloads", "Library", "Movies", "Music",
            "Pictures", "Applications",
        ]
        if standardChildren.contains(where: { clean == home + "/" + $0 }) { return true }
        return false
    }
}

/// "What happens if I delete this" hints (design 1e rule 3): tell the user
/// what regenerates, and warn on the one amber case — the only backup of a
/// device.
struct CleanupHint: Equatable {
    let text: String
    let isWarning: Bool

    static let none = CleanupHint(text: "", isWarning: false)

    static func forPath(_ path: String) -> CleanupHint {
        let p = path
        func hint(_ t: String) -> CleanupHint { CleanupHint(text: t, isWarning: false) }
        func warn(_ t: String) -> CleanupHint { CleanupHint(text: t, isWarning: true) }

        if p.contains("/MobileSync/Backup") {
            return warn("May be the only backup of this device")
        }
        if p.contains("/Xcode/DerivedData") || p.hasSuffix("/DerivedData")
            || p.contains("/DerivedData/")
        {
            return hint("Xcode rebuilds this automatically")
        }
        if p.hasSuffix("/Docker.raw") || p.contains("/com.docker.docker/") {
            return hint("Regenerates next time Docker runs")
        }
        if p.hasSuffix("/node_modules") || p.contains("/node_modules/") {
            return hint("npm/yarn install re-creates this")
        }
        if p.contains("/Library/Caches") || p.hasSuffix("/Caches") {
            return hint("Apps rebuild caches as needed")
        }
        if p.contains("/CoreSimulator/Devices") {
            return hint("Simulator runtimes re-download on demand")
        }
        if p.contains("/Downloads/") {
            let lower = p.lowercased()
            for ext in [".dmg", ".xip", ".pkg", ".zip", ".iso"] where lower.hasSuffix(ext) {
                return hint("Installer/archive — usually safe once installed")
            }
        }
        if p.contains("/.Trash/") {
            return hint("Already in the Trash")
        }
        if p.hasSuffix("/target") || p.contains("/target/debug") || p.contains("/target/release") {
            return hint("cargo build re-creates this")
        }
        return .none
    }
}
