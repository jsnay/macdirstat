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
    func testNoErrorsMeansNoCTARegardlessOfGap() {
        XCTAssertNil(FooterIndicators.fdaMessage(errorCount: 0))
    }

    func testCTACountsLocationsNotBytes() {
        XCTAssertEqual(
            FooterIndicators.fdaMessage(errorCount: 1),
            "1 location couldn't be read — Grant Full Disk Access…")
        XCTAssertEqual(
            FooterIndicators.fdaMessage(errorCount: 12),
            "12 locations couldn't be read — Grant Full Disk Access…")
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
