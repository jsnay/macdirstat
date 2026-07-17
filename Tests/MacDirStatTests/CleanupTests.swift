import XCTest

@testable import MacDirStat

// =============================================================================
// FILE: Tests/MacDirStatTests/CleanupTests.swift
// =============================================================================
//
// PURPOSE
//   Unit checks for the PURE app-side logic — the pieces that hold user
//   safety and visual consistency but need no engine, no filesystem, and
//   no UI: the cleanup system-path guard, the path-aware deletion hints,
//   and palette completeness. Engine correctness (sizes, sorting, layout,
//   dedup) is proven in dirstat-core's own suite and deliberately NOT
//   re-proven here; UI/integration coverage (EVA-*) is deferred to a
//   macOS UI-test runner.
//
// UPSTREAM DEPENDENCIES (what this file consumes)
//   - @testable MacDirStat: CleanupGuard, CleanupHint, Palette,
//     KindCategory.
//   - XCTest; FileManager only to resolve the real home directory so the
//     home-folder guard cases test the machine's actual paths.
//
// STRUCTURE
//   - CleanupGuardTests: refusals (system paths, home roots), allowances
//     (ordinary user files), and the /System/Volumes/Data canonicalization
//     cases from the field-reported "even a .mov is system-critical" bug
//   - CleanupHintTests: regeneration hints + the only-backup amber warning
//   - PaletteTests: every category has a color; channel table sizes are
//     pinned (5 age buckets, 12 extension slots + "everything else")
// =============================================================================

/// EVA-level unit checks for the pure app-side logic behind design 1e/1g
/// (engine correctness is proven in dirstat-core's own suite, not here).
final class CleanupGuardTests: XCTestCase {
    func testSystemCriticalPathsRefused() {
        // Design 1e rule: system paths can't be staged at all.
        for path in [
            "/", "/System", "/System/Library", "/usr/bin", "/private/etc/hosts",
            "/Applications", "/Library", "/bin/ls",
        ] {
            XCTAssertTrue(
                CleanupGuard.isSystemCritical(path: path), "\(path) must be refused")
        }
    }

    func testHomeRootAndStandardFoldersRefused() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertTrue(CleanupGuard.isSystemCritical(path: home))
        XCTAssertTrue(CleanupGuard.isSystemCritical(path: home + "/Documents"))
        XCTAssertTrue(CleanupGuard.isSystemCritical(path: home + "/Library"))
    }

    func testOrdinaryUserPathsAllowed() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in [
            home + "/Downloads/Xcode_16.2.xip",
            home + "/Library/Developer/Xcode/DerivedData/Proj-abc",
            home + "/dev/project/node_modules",
            home + "/Movies/Old Render.mov",
        ] {
            XCTAssertFalse(
                CleanupGuard.isSystemCritical(path: path), "\(path) must be stageable")
        }
    }

    /// The APFS Data volume re-exposes user files under
    /// /System/Volumes/Data/…; they must be judged by their canonical
    /// location, not refused by the /System/ rule (the "even a .mov is
    /// system-critical" bug).
    func testDataVolumePathsJudgedCanonically() {
        XCTAssertFalse(
            CleanupGuard.isSystemCritical(
                path: "/System/Volumes/Data/Users/alex/Movies/Old Render.mov"))
        XCTAssertFalse(
            CleanupGuard.isSystemCritical(
                path: "/System/Volumes/Data/Users/alex/Library/Caches/com.foo"))
        // The canonical guards still apply through the prefix.
        XCTAssertTrue(CleanupGuard.isSystemCritical(path: "/System/Volumes/Data"))
        XCTAssertTrue(CleanupGuard.isSystemCritical(path: "/System/Volumes/Data/Users"))
        XCTAssertTrue(
            CleanupGuard.isSystemCritical(path: "/System/Volumes/Data/private/etc/hosts"))
        // Real System-volume paths remain refused.
        XCTAssertTrue(CleanupGuard.isSystemCritical(path: "/System/Library/Kernels"))
    }
}

final class CleanupHintTests: XCTestCase {
    func testRegenerationHints() {
        XCTAssertEqual(
            CleanupHint.forPath("/Users/a/Library/Developer/Xcode/DerivedData/P-xyz").text,
            "Xcode rebuilds this automatically")
        XCTAssertEqual(
            CleanupHint.forPath(
                "/Users/a/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"
            ).text,
            "Regenerates next time Docker runs")
        XCTAssertEqual(
            CleanupHint.forPath("/Users/a/dev/app/node_modules").text,
            "npm/yarn install re-creates this")
    }

    func testOnlyBackupWarnsAmber() {
        let hint = CleanupHint.forPath(
            "/Users/a/Library/Application Support/MobileSync/Backup/abcdef")
        XCTAssertTrue(hint.isWarning)
    }

    func testUnknownPathHasNoHint() {
        XCTAssertEqual(CleanupHint.forPath("/Users/a/notes.txt"), .none)
    }
}

final class PaletteTests: XCTestCase {
    func testEveryCategoryHasAColor() {
        for category in KindCategory.allCases {
            XCTAssertNotNil(Palette.kind[category], "\(category.label) missing a color")
        }
    }

    func testChannelsAreComplete() {
        // 5 age buckets, 12 extension slots + "everything else" (1g).
        XCTAssertEqual(Palette.age.count, 5)
        XCTAssertEqual(Palette.ageLabels.count, 5)
        XCTAssertEqual(Palette.extensionSlots.count, 13)
    }
}

// MARK: - FileIdentity / TOCTOU (app#6)

final class FileIdentityTests: XCTestCase {
    private func tempFile(_ name: String) -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mds-id-\(name)-\(getpid())")
        FileManager.default.createFile(atPath: url.path, contents: Data(count: 8))
        return url.path
    }

    func testLstatRoundTrip() {
        let path = tempFile("round")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let a = FileIdentity.lstat(path)
        let b = FileIdentity.lstat(path)
        XCTAssertNotNil(a)
        XCTAssertEqual(a, b, "same file → same identity")
    }

    func testMissingPathIsNil() {
        XCTAssertNil(FileIdentity.lstat("/nonexistent/mds/\(getpid())"))
    }

    /// The core TOCTOU signal: replacing the file at a path yields a
    /// different (device, inode), which the commit gate detects.
    func testReplacedFileHasDifferentIdentity() throws {
        let path = tempFile("swap")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let before = FileIdentity.lstat(path)
        // Remove and recreate: a new inode.
        try FileManager.default.removeItem(atPath: path)
        FileManager.default.createFile(atPath: path, contents: Data(count: 8))
        let after = FileIdentity.lstat(path)
        XCTAssertNotNil(before)
        XCTAssertNotNil(after)
        XCTAssertNotEqual(before, after, "a replaced file must not match its staged identity")
    }

    /// lstat does not follow a final symlink: a link and its target have
    /// distinct identities, so swapping a path for a symlink is detected.
    func testSymlinkNotFollowed() throws {
        let target = tempFile("target")
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("mds-id-link-\(getpid())").path
        defer {
            try? FileManager.default.removeItem(atPath: target)
            try? FileManager.default.removeItem(atPath: link)
        }
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let targetId = FileIdentity.lstat(target)
        let linkId = FileIdentity.lstat(link)
        XCTAssertNotNil(linkId)
        XCTAssertNotEqual(targetId, linkId, "lstat sees the link itself, not its target")
    }
}

// MARK: - SecurityChecks (app#9)

final class SecurityCheckTests: XCTestCase {
    func testRootIsRefused() {
        XCTAssertTrue(SecurityChecks.isRunningAsRoot(euid: 0))
    }
    func testNormalUserIsAllowed() {
        XCTAssertFalse(SecurityChecks.isRunningAsRoot(euid: 501))
        XCTAssertFalse(SecurityChecks.isRunningAsRoot(euid: 1000))
    }
}

// MARK: - ByteFormat

final class ByteFormatTests: XCTestCase {
    func testMagnitudeBoundaries() {
        XCTAssertEqual(ByteFormat.compact(0), "0 KB")
        XCTAssertEqual(ByteFormat.compact(1_000_000), "1 MB")
        XCTAssertEqual(ByteFormat.compact(1_000_000_000), "1.0 GB")
        XCTAssertEqual(ByteFormat.compact(1_000_000_000_000), "1.00 TB")
    }
    func testGigabyteHasOneDecimal() {
        XCTAssertEqual(ByteFormat.compact(1_500_000_000), "1.5 GB")
    }
}

// MARK: - FooterIndicators (app#13)

/// The field bug: with FDA granted, the footer showed "72.3 GB unreadable —
/// Grant Full Disk Access" — but that number was the APFS capacity gap
/// (snapshots, sibling container volumes, purgeable), which no permission
/// grant can clear. The CTA must key off actual read failures; the gap
/// gets a neutral label and only for whole-volume scans.
final class FooterIndicatorTests: XCTestCase {
    func testNoErrorsMeansNoIndicatorRegardlessOfGrant() {
        XCTAssertNil(FooterIndicators.readFailures(errorCount: 0, fdaGranted: nil))
        XCTAssertNil(FooterIndicators.readFailures(errorCount: 0, fdaGranted: true))
        XCTAssertNil(FooterIndicators.readFailures(errorCount: 0, fdaGranted: false))
    }

    func testCTACountsLocationsNotBytes() {
        let one = FooterIndicators.readFailures(errorCount: 1, fdaGranted: false)
        XCTAssertEqual(one?.text, "1 location couldn't be read — Grant Full Disk Access…")
        XCTAssertEqual(one?.isCTA, true)
        let many = FooterIndicators.readFailures(errorCount: 12, fdaGranted: false)
        XCTAssertEqual(many?.text, "12 locations couldn't be read — Grant Full Disk Access…")
    }

    /// The round-2 field bug (app#19): FDA granted, 217 root-owned dirs
    /// still unreadable — the CTA must NOT appear; neutral wording does.
    func testGrantedFDAMakesFailuresNeutralNotCTA() {
        let ind = FooterIndicators.readFailures(errorCount: 217, fdaGranted: true)
        XCTAssertEqual(ind?.isCTA, false)
        XCTAssertEqual(ind?.text, "217 system-protected locations couldn't be read")
        XCTAssertFalse(ind!.text.contains("Full Disk Access"))
    }

    /// Inconclusive probe defaults to the CTA — pointing at the pane is
    /// the safe direction when we can't tell.
    func testInconclusiveProbeDefaultsToCTA() {
        XCTAssertEqual(
            FooterIndicators.readFailures(errorCount: 3, fdaGranted: nil)?.isCTA, true)
    }

    func testGapIsNeutralAndNamesTheRealCauses() {
        let gap = FooterIndicators.gapMessage(
            unknown: 72_300_000_000, isFullVolumeScan: true)
        XCTAssertEqual(gap, "72.3 GB in snapshots, system volumes & purgeable space")
        XCTAssertFalse(gap!.contains("Full Disk Access"), "the gap must never be a CTA")
    }

    func testGapHiddenForFolderScans() {
        XCTAssertNil(
            FooterIndicators.gapMessage(unknown: 500_000_000_000, isFullVolumeScan: false))
    }

    func testNegligibleGapHidden() {
        XCTAssertNil(FooterIndicators.gapMessage(unknown: 900_000_000, isFullVolumeScan: true))
    }
}

// MARK: - CapacityBreakdown (app#17)

/// The clamped partition of the capacity gap. Inputs come from different
/// subsystems (statfs, resource values) and may overlap or overshoot; the
/// partition must never let the segments exceed the gap.
final class CapacityBreakdownTests: XCTestCase {
    func testPartitionAllFits() {
        let b = CapacityBreakdown.partition(
            unknown: 100, systemVolumesUsed: 30, purgeableEstimate: 50)
        XCTAssertEqual(b.systemVolumes, 30)
        XCTAssertEqual(b.purgeable, 50)
        XCTAssertEqual(b.snapshotsAndMetadata, 20)
    }

    func testSystemVolumesClampToGap() {
        let b = CapacityBreakdown.partition(
            unknown: 25, systemVolumesUsed: 40, purgeableEstimate: 10)
        XCTAssertEqual(b.systemVolumes, 25)
        XCTAssertEqual(b.purgeable, 0)
        XCTAssertEqual(b.snapshotsAndMetadata, 0)
    }

    func testPurgeableClampsToRemainder() {
        let b = CapacityBreakdown.partition(
            unknown: 60, systemVolumesUsed: 40, purgeableEstimate: 100)
        XCTAssertEqual(b.systemVolumes, 40)
        XCTAssertEqual(b.purgeable, 20)
        XCTAssertEqual(b.snapshotsAndMetadata, 0)
    }

    func testSegmentsAlwaysSumToGap() {
        for (unknown, sys, purge) in
            [(0 as UInt64, 0 as UInt64, 0 as UInt64), (73_600_000_000, 14_000_000_000, 30_000_000_000),
             (10, 100, 100), (5, 0, 100)]
        {
            let b = CapacityBreakdown.partition(
                unknown: unknown, systemVolumesUsed: sys, purgeableEstimate: purge)
            XCTAssertEqual(
                b.systemVolumes + b.purgeable + b.snapshotsAndMetadata, unknown,
                "partition must be exact for (\(unknown), \(sys), \(purge))")
        }
    }
}

// MARK: - AppLog retention (app#20)

/// The pure pruning decision: 90-day retention plus a size cap, and we
/// only ever delete files whose names we provably wrote.
final class AppLogTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private var now: Date { AppLog.date(fromFileName: "macdirstat-2026-07-17.log")! }

    private func name(daysAgo: Int) -> String {
        AppLog.fileName(for: now.addingTimeInterval(-Double(daysAgo) * day))
    }

    func testFileNameRoundTrip() {
        XCTAssertEqual(AppLog.fileName(for: now), "macdirstat-2026-07-17.log")
        XCTAssertEqual(AppLog.date(fromFileName: "macdirstat-2026-07-17.log"), now)
        XCTAssertNil(AppLog.date(fromFileName: "something-else.log"))
        XCTAssertNil(AppLog.date(fromFileName: "macdirstat-garbage.log"))
    }

    func testExpiredFilesPruned() {
        let doomed = AppLog.filesToPrune(
            files: [
                (name(daysAgo: 91), 100), (name(daysAgo: 89), 100), (name(daysAgo: 0), 100),
            ],
            now: now, retentionDays: 90, sizeCap: 1_000_000)
        XCTAssertEqual(doomed, [name(daysAgo: 91)])
    }

    func testSizeCapDropsOldestFirst() {
        let doomed = AppLog.filesToPrune(
            files: [
                (name(daysAgo: 3), 400), (name(daysAgo: 2), 400), (name(daysAgo: 1), 400),
            ],
            now: now, retentionDays: 90, sizeCap: 800)
        XCTAssertEqual(doomed, [name(daysAgo: 3)])
    }

    func testForeignFilesNeverPruned() {
        let doomed = AppLog.filesToPrune(
            files: [("notes.txt", 999_999_999), (name(daysAgo: 200), 10)],
            now: now, retentionDays: 90, sizeCap: 100)
        XCTAssertEqual(doomed, [name(daysAgo: 200)])
    }
}

// MARK: - VolumeInfo logic

final class VolumeInfoTests: XCTestCase {
    private func vol(path: String, total: UInt64, free: UInt64) -> VolumeInfo {
        VolumeInfo(url: URL(fileURLWithPath: path), name: "V", total: total, free: free, isInternal: true)
    }

    func testLowSpaceThreshold() {
        XCTAssertTrue(vol(path: "/", total: 1000, free: 90).isLowOnSpace)   // 9% free
        XCTAssertFalse(vol(path: "/", total: 1000, free: 110).isLowOnSpace) // 11% free
    }

    func testUsedAndFractions() {
        let v = vol(path: "/", total: 1000, free: 250)
        XCTAssertEqual(v.used, 750)
        XCTAssertEqual(v.usedFraction, 0.75, accuracy: 0.0001)
        XCTAssertEqual(v.freeFraction, 0.25, accuracy: 0.0001)
    }

    /// The boot volume ("/") scans via the APFS Data volume when present;
    /// arbitrary folders pass through unchanged.
    func testScanPathRouting() {
        let dataExists = FileManager.default.fileExists(atPath: "/System/Volumes/Data")
        let boot = vol(path: "/", total: 1000, free: 500)
        if dataExists {
            XCTAssertEqual(boot.scanPath, "/System/Volumes/Data")
        } else {
            XCTAssertEqual(boot.scanPath, "/")
        }
        let folder = vol(path: "/Users/someone/dev", total: 1000, free: 500)
        XCTAssertEqual(folder.scanPath, "/Users/someone/dev")
    }
}
