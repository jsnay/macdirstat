import AppKit
import Combine
import Foundation

// =============================================================================
// FILE: Sources/MacDirStat/Model/CleanupStore.swift
// =============================================================================
//
// PURPOSE
//   The staged, Trash-first cleanup flow (design 1e). The core decision is
//   that DECIDING is separated from DOING: users stage items into a list
//   (with a running reclaim total), review once, and commit once — always
//   to the Trash, never permanently. This file holds all three pieces of
//   that flow: the staging store, the path-based safety rails that refuse
//   system-critical targets, and the "what happens if I delete this"
//   regeneration hints shown in the review sheet.
//
// UPSTREAM DEPENDENCIES (what this file consumes)
//   - Engine/Engine.swift: NodeID (staging key), EngineModel (path/info to
//     build StagedItem; refresh after each trash), KindCategory (row swatch).
//   - AppKit/Foundation: FileManager.trashItem (the ONLY deletion API used)
//     and homeDirectoryForCurrentUser for the guard rules.
//   - Combine: ObservableObject/@Published for the pill/sheet/striping UI.
//
// DOWNSTREAM CONSUMERS (who depends on this file)
//   - Model/AppState.swift: owns the one CleanupStore; toggleCleanup and
//     commitCleanup funnel through it and surface failures as alerts.
//   - Views/MainView.swift: CleanupPill + FooterContent observe items /
//     total / lastReclaimed; MainContent observes reviewPresented.
//   - Views/TreemapPane.swift: stagedNodes drives the amber striping.
//   - Views/SidebarOutline.swift: stagedNodes labels the context menu.
//   - Views/CleanupReviewSheet.swift: items/total/remove/commit UI.
//   - Tests/MacDirStatTests/CleanupTests.swift: CleanupGuard + CleanupHint
//     (the pure-logic pieces, testable without an engine).
//
// STRUCTURE
//   - CleanupStore: staged items + toggle/remove/clear + commitToTrash
//   - CleanupGuard: system-critical path rules + Data-volume canonicalize
//   - CleanupHint: per-path regeneration hints + the one amber warning
//
// BEHAVIOR & INVARIANTS
//   - @MainActor throughout; commitToTrash is async but stays on the main
//     actor (trashItem is quick per item; the engine refresh dominates).
//   - StagedItem.size is PHYSICAL bytes, always: "frees N GB" is a promise
//     about the disk, and only allocated bytes come back from the Trash.
//   - Staging is refused for system-critical paths at STAGE time (rule 4),
//     so the review sheet can promise its list is committable.
//   - Paths under /System/Volumes/Data/... are judged by their canonical
//     firmlinked location — real user files live under that prefix when
//     the boot volume is scanned via the Data volume.
// =============================================================================

// MARK: - CleanupStore: staging + commit

/// Cleanup staging (design 1e): deciding is separated from doing. Items
/// collect here with a running reclaim total; one review, one commit — to
/// Trash, always. "Delete Permanently" is deliberately not a button this
/// store offers.
@MainActor
final class CleanupStore: ObservableObject {
    /// One staged deletion, snapshotted at STAGE time (name/path/size/hint
    /// are captured then, not at commit — the review sheet must not need
    /// engine calls per row, and the promise shown is the promise kept).
    struct StagedItem: Identifiable, Equatable {
        let node: NodeID
        let name: String
        let path: String
        /// Physical (allocated) bytes — see the file-header invariant.
        let size: UInt64
        let category: KindCategory
        /// Regeneration hint / amber warning for the review row.
        let hint: CleanupHint
        /// Filesystem identity captured at STAGE time (device + inode, via
        /// lstat so symlinks are not followed). Re-verified immediately
        /// before the trash call so a same-user process can't swap the path
        /// for a different file/symlink in between (TOCTOU — dirstat-core
        /// app#6). `nil` if the stat failed at staging.
        let identity: FileIdentity?
        var id: UInt64 { node.raw }
    }

    /// The staged list, in staging order (the review sheet's rows).
    @Published private(set) var items: [StagedItem] = []
    /// Presents the CleanupReviewSheet (bound from MainContent).
    @Published var reviewPresented = false
    /// Set briefly after a commit so the UI can show the space returning.
    /// Auto-clears after ~4s (see commitToTrash).
    @Published private(set) var lastReclaimed: UInt64?

    /// Running reclaim total — the number on the Cleanup pill.
    var total: UInt64 { items.reduce(0) { $0 + $1.size } }
    /// Set view of staged nodes for O(1) membership tests (treemap
    /// striping checks this per rect per frame).
    var stagedNodes: Set<NodeID> { Set(items.map(\.node)) }

    /// Outcome of `toggle`, so AppState can turn refusals into alerts.
    enum StageResult: Equatable {
        case staged
        case unstaged
        case refusedSystemCritical
        /// Name isn't valid UTF-8: the lossy path could denote a different
        /// file, so destructive action is refused (security, app#5).
        case refusedUnsafeName
        case failed
    }

    /// Toggle a node in/out of the cleanup list. System-critical paths and
    /// non-UTF-8 names can't be staged at all — both refusals happen here,
    /// at stage time, never as a surprise at commit time.
    func toggle(node: NodeID, model: EngineModel) -> StageResult {
        // Already staged → unstage (the same menu item does both).
        if let index = items.firstIndex(where: { $0.node == node }) {
            items.remove(at: index)
            return .unstaged
        }
        guard let info = try? model.info(node) else { return .failed }
        // Non-UTF-8 names: the string path is lossy and could collide with a
        // different real file. Refuse destructive staging entirely (app#5).
        guard !info.hasNonUTF8Name else {
            return .refusedUnsafeName
        }
        // Guard check runs on the engine's absolute path (canonicalized
        // inside the guard for Data-volume prefixes).
        let path = model.path(of: node)
        guard !CleanupGuard.isSystemCritical(path: path) else {
            return .refusedSystemCritical
        }
        items.append(
            StagedItem(
                node: node,
                name: model.name(of: node),
                path: path,
                // Physical bytes: "frees N GB" is a promise about the disk.
                size: info.physical,
                category: info.category,
                hint: CleanupHint.forPath(path),
                // Capture identity now; re-checked before the trash call.
                identity: FileIdentity.lstat(path)))
        return .staged
    }

    /// Unstage one item (the review sheet's per-row "keep this" X).
    func remove(_ item: StagedItem) {
        items.removeAll { $0.node == item.node }
    }

    /// Drop all staged items (new scan / back to picker).
    func clear() {
        items = []
    }

    /// Commit: move every staged item to the Trash (never permanent —
    /// APP-ACT-6), then refresh each affected node in the engine so all
    /// panes reconcile (APP-ACT-12). Returns paths that failed.
    ///
    /// The loop is deliberately per-item: each item is trashed, then ITS
    /// engine node is refreshed right away, so a failure mid-list leaves
    /// the model consistent with whatever actually happened on disk.
    /// The refresh is `try?` — the expected outcome is "node vanished",
    /// which the engine may report as an error for the id.
    func commitToTrash(model: EngineModel) async -> [String] {
        var failures: [String] = []
        // Capture the promised total BEFORE mutating the list, for the
        // "Reclaimed N ✓" toast.
        let reclaim = total
        for item in items {
            // TOCTOU gate (app#6): re-verify the path still resolves to the
            // exact (device, inode) captured at staging. A same-user process
            // could have swapped a path component for a symlink or replaced
            // the file since the user reviewed it; trashing by the stale path
            // would then hit a file they never saw. lstat (no symlink follow)
            // and require an identity match, or skip this item.
            let now = FileIdentity.lstat(item.path)
            guard let staged = item.identity, let now, now == staged else {
                failures.append(
                    "\(item.path): changed on disk since you staged it — re-stage to delete")
                continue
            }
            let url = URL(fileURLWithPath: item.path)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                try? model.refresh(item.node)
            } catch {
                failures.append("\(item.path): \(error.localizedDescription)")
            }
        }
        // The list clears even on partial failure: the failed paths are
        // reported via the returned array (AppState alerts), and stale
        // staged rows would point at nodes the engine just re-read anyway.
        items = []
        reviewPresented = false
        if failures.isEmpty {
            // Show "the space returning" (1e), then auto-dismiss.
            lastReclaimed = reclaim
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.lastReclaimed = nil
            }
        }
        return failures
    }
}

// MARK: - FileIdentity: TOCTOU-safe filesystem identity

/// A file's (device, inode) pair, read with `lstat` so a symlink resolves
/// to the LINK itself, not its target. Comparing the value captured at
/// staging with a fresh read just before deletion detects any swap of the
/// path to a different file or a symlink in between (app#6). Pure and
/// synchronous; testable without an engine.
struct FileIdentity: Equatable {
    let device: UInt64
    let inode: UInt64

    /// lstat the path; nil if it does not exist or cannot be stat'd.
    static func lstat(_ path: String) -> FileIdentity? {
        var st = stat()
        // Darwin lstat: does not follow a final symlink.
        guard Foundation.lstat(path, &st) == 0 else { return nil }
        return FileIdentity(device: UInt64(bitPattern: Int64(st.st_dev)), inode: st.st_ino)
    }
}

// MARK: - CleanupGuard: system-critical path rules

/// Path-aware safety rails (design 1e): block the paths where deletion is
/// never what the user means. Two rule shapes on purpose — EXACT matches
/// for directories whose children are legitimate targets, and PREFIX
/// matches for trees where nothing inside is ever safe to stage.
enum CleanupGuard {
    /// Prefixes that can never be staged. Children of some of them are
    /// fine (~/Library/Caches is a classic cleanup target); it's the roots
    /// and OS directories that are off-limits.
    static let forbiddenExact: Set<String> = [
        "/", "/System", "/Library", "/Applications", "/Users", "/usr", "/bin",
        "/sbin", "/etc", "/var", "/private", "/private/var", "/private/etc",
        "/opt", "/Volumes", "/cores", "/dev",
    ]

    /// Whole trees that are off-limits including everything inside them
    /// (OS binaries and config; SIP protects most of these anyway, but the
    /// app should refuse before the OS has to).
    static let forbiddenPrefixes: [String] = [
        "/System/", "/usr/", "/bin/", "/sbin/", "/private/etc/",
    ]

    /// The APFS Data volume re-exposes the user's world under
    /// `/System/Volumes/Data/...`; judge those paths by their canonical
    /// firmlinked location (`/Users/...`), or every real file would be
    /// refused by the `/System/` rule.
    ///
    /// This matters because scanning the boot volume actually scans
    /// /System/Volumes/Data (see AppState.startScan), so EVERY node path
    /// from such a scan carries this prefix — without canonicalization the
    /// cleanup feature would refuse even a .mov in the user's Movies
    /// folder (the bug the tests pin down). Stripping the prefix maps the
    /// Data volume root to "/" and everything else to its familiar alias,
    /// and the normal rules then apply to the canonical form.
    static func canonicalize(_ path: String) -> String {
        let dataPrefix = "/System/Volumes/Data"
        if path == dataPrefix { return "/" }
        if path.hasPrefix(dataPrefix + "/") {
            return String(path.dropFirst(dataPrefix.count))
        }
        return path
    }

    /// The single staging gate (design 1e rule 4). Checks, in order:
    /// canonicalize → trim trailing slash → exact forbidden set → forbidden
    /// prefixes → the home directory itself → the home's top-level standard
    /// folders. Anything else — including files INSIDE those folders — is
    /// stageable.
    static func isSystemCritical(path: String) -> Bool {
        let path = canonicalize(path)
        // Normalize a trailing "/" (but keep "/" itself) so directory
        // paths match the rule tables however callers spell them.
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

// MARK: - CleanupHint: regeneration hints

/// "What happens if I delete this" hints (design 1e rule 3): tell the user
/// what regenerates, and warn on the one amber case — the only backup of a
/// device.
struct CleanupHint: Equatable {
    let text: String
    /// True only for the amber case (irreplaceable data); everything else
    /// is a reassurance, not a warning.
    let isWarning: Bool

    static let none = CleanupHint(text: "", isWarning: false)

    /// Match well-known reclaimable locations by path shape. First match
    /// wins, so the amber MobileSync warning is checked before any
    /// reassuring hint could shadow it. Purely lexical — no filesystem
    /// access — so it is fast and unit-testable.
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
