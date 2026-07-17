import Foundation
import os

// =============================================================================
// FILE: Sources/MacDirStat/Model/AppLog.swift
// =============================================================================
//
// PURPOSE
//   Local, privacy-preserving trace logging (app#20). Field bugs like the
//   capacity-gap mislabeling (#13/#19) were only diagnosable with the
//   reporter in the room; this gives every install a bounded, greppable
//   record of the app's decisions. Lines go to a per-day file under
//   ~/Library/Logs/MacDirStat and are mirrored to the unified log
//   (subsystem com.macdirstat.app) for live Console.app debugging.
//
// UPSTREAM DEPENDENCIES (what this file consumes)
//   - Foundation (FileManager/FileHandle/DateFormatter), os.Logger.
//
// DOWNSTREAM CONSUMERS (who depends on this file)
//   - Model/AppState.swift: scan lifecycle, reconciliation, FDA probe.
//   - Model/CleanupStore.swift: staging decisions, TOCTOU trips, commits.
//   - Engine/Engine.swift: EngineLogBridge routes ds_set_log_callback here.
//   - MacDirStatApp.swift: launch line, root refusal, prune-at-launch.
//   - Tests/MacDirStatTests/CleanupTests.swift: the pure pruning logic.
//
// BEHAVIOR & INVARIANTS
//   - PRIVACY: log lines contain scanned paths. They never leave the
//     machine — the app has no network access by design — and retention
//     is bounded (below). The README documents location and posture.
//   - RETENTION: files older than 90 days are deleted at launch, and the
//     directory is capped at 50 MB (oldest files dropped first). The
//     decision function is pure and unit-tested; only the executor
//     touches the filesystem.
//   - VOLUME: call sites log summaries and decisions, never per-file
//     lines — a scan of any size produces a bounded number of entries
//     (the engine's callback holds the same contract on its side).
//   - Writes are serialized on one utility queue; `log` is safe to call
//     from any thread, including engine worker threads.
// =============================================================================

enum AppLog {
    static let retentionDays = 90
    static let sizeCapBytes: UInt64 = 50_000_000

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacDirStat", isDirectory: true)
    }

    private static let queue = DispatchQueue(
        label: "com.macdirstat.applog", qos: .utility)
    private static let unified = Logger(subsystem: "com.macdirstat.app", category: "app")

    /// Log one line: `2026-07-17T14:03:22Z [scan] message`. Thread-safe;
    /// the file write is async on the serial queue, the unified-log mirror
    /// is immediate. `.public` because these logs exist to be read off the
    /// user's own machine — TCC already gates who can read them.
    static func log(_ category: String, _ message: String) {
        let line = "\(timestampFormatter.string(from: Date())) [\(category)] \(message)"
        unified.info("\(line, privacy: .public)")
        queue.async { append(line: line, at: Date()) }
    }

    /// Delete expired/over-cap logs. Call once at launch, off the main
    /// thread (it shares the write queue so it can't race a log line).
    static func pruneAtLaunch() {
        queue.async {
            let fm = FileManager.default
            guard
                let names = try? fm.contentsOfDirectory(atPath: directory.path)
            else { return }
            let files = names.map { name -> (name: String, size: UInt64) in
                let attrs = try? fm.attributesOfItem(
                    atPath: directory.appendingPathComponent(name).path)
                return (name, (attrs?[.size] as? UInt64) ?? 0)
            }
            for doomed in filesToPrune(
                files: files, now: Date(),
                retentionDays: retentionDays, sizeCap: sizeCapBytes)
            {
                try? fm.removeItem(at: directory.appendingPathComponent(doomed))
            }
        }
    }

    // MARK: - Pure logic (unit-tested)

    /// Log file name for a date: `macdirstat-2026-07-17.log`.
    static func fileName(for date: Date) -> String {
        "macdirstat-\(dayFormatter.string(from: date)).log"
    }

    /// The date encoded in a log file name, or nil for anything that isn't
    /// ours (unparseable names are never pruned — we only delete what we
    /// provably wrote).
    static func date(fromFileName name: String) -> Date? {
        guard name.hasPrefix("macdirstat-"), name.hasSuffix(".log") else { return nil }
        let day = name.dropFirst("macdirstat-".count).dropLast(".log".count)
        return dayFormatter.date(from: String(day))
    }

    /// The pruning decision (pure): expired files first (older than
    /// `retentionDays`), then — if the survivors still exceed `sizeCap` —
    /// oldest survivors until the total fits. Files whose names we can't
    /// parse are untouchable.
    static func filesToPrune(
        files: [(name: String, size: UInt64)],
        now: Date,
        retentionDays: Int,
        sizeCap: UInt64
    ) -> [String] {
        let cutoff = now.addingTimeInterval(-Double(retentionDays) * 86_400)
        var doomed: [String] = []
        var survivors: [(name: String, size: UInt64, date: Date)] = []
        for f in files {
            guard let d = date(fromFileName: f.name) else { continue }
            if d < cutoff {
                doomed.append(f.name)
            } else {
                survivors.append((f.name, f.size, d))
            }
        }
        var total = survivors.reduce(0) { $0 + $1.size }
        for f in survivors.sorted(by: { $0.date < $1.date }) where total > sizeCap {
            doomed.append(f.name)
            total -= f.size
        }
        return doomed
    }

    // MARK: - Plumbing

    private static func append(line: String, at date: Date) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName(for: date))
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: url.path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
