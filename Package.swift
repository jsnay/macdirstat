// swift-tools-version: 5.9
// MacDirStat — native macOS host for the dirstat-core Rust engine.
//
// Build the engine first (`make engine` or Scripts/build-engine.sh); it
// drops libdirstat_core.a into .lib/. Then `swift build` / `make run`.
import PackageDescription

let package = Package(
    name: "MacDirStat",
    platforms: [.macOS(.v14)],
    targets: [
        // The pinned C header for the engine ABI (APP-FFI-6): this copy is
        // checked in and must match the engine's generated header; the
        // wrapper also verifies ds_abi_version() at startup.
        .target(
            name: "CDirstatCore",
            path: "Sources/CDirstatCore"
        ),
        .executableTarget(
            name: "MacDirStat",
            dependencies: ["CDirstatCore"],
            path: "Sources/MacDirStat",
            linkerSettings: [
                .linkedLibrary("dirstat_core"),
                .unsafeFlags(["-L", ".lib"]),
            ]
        ),
        .testTarget(
            name: "MacDirStatTests",
            dependencies: ["MacDirStat"],
            path: "Tests/MacDirStatTests"
        ),
    ]
)
