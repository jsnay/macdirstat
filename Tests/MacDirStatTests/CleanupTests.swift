import XCTest

@testable import MacDirStat

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
