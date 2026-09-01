// swift-tools-version: 5.9
import PackageDescription

// The AppKit app exists only on macOS. The manifest itself is Swift and
// evaluates on the build host, so the app target is appended only there —
// plain `swift build` / `swift test` work on Linux too (core + tray)
// without #if litter through the app sources.
var targets: [Target] = [
    // Pure layer: models, feed decoding, supervisor state machine.
    // No AppKit import — everything here runs under `swift test`.
    .target(name: "CswapCore", path: "Sources/CswapCore"),
    // Linux/Omarchy frontend: a Waybar custom module over the same core
    // (packaging/omarchy). The engine stays behind `cswap … --json`.
    .executableTarget(
        name: "InfinitusTray",
        dependencies: ["CswapCore"],
        path: "Sources/InfinitusTray"
    ),
    .testTarget(
        name: "CswapCoreTests",
        dependencies: ["CswapCore"],
        path: "Tests/CswapCoreTests",
        resources: [.copy("Fixtures")]
    ),
]
#if os(macOS)
targets.append(.executableTarget(
    name: "Infinitus",
    dependencies: ["CswapCore"],
    path: "Sources/Infinitus"
))
#endif

let package = Package(
    name: "Infinitus",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "infinitus-tray", targets: ["InfinitusTray"]),
        .library(name: "CswapCore", targets: ["CswapCore"]),
    ],
    targets: targets
)
