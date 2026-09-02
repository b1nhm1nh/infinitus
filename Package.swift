// swift-tools-version: 5.9
import PackageDescription

// The AppKit app exists only on macOS. The manifest itself is Swift and
// evaluates on the build host, so the app target is appended only there —
// plain `swift build` / `swift test` work on Linux too (core + tray)
// without #if litter through the app sources.
var targets: [Target] = [
    // Pure layer: models, feed decoding, supervisor state machine.
    // No AppKit import — everything here runs under `swift test`.
    .target(name: "InfinitusCore", path: "Sources/InfinitusCore"),
    // Linux/Omarchy frontend: a Waybar custom module over the same core
    // (packaging/omarchy). The engine stays behind `cswap … --json`.
    .executableTarget(
        name: "InfinitusTray",
        dependencies: ["InfinitusCore"],
        path: "Sources/InfinitusTray"
    ),
    .testTarget(
        name: "InfinitusCoreTests",
        dependencies: ["InfinitusCore"],
        path: "Tests/InfinitusCoreTests",
        resources: [.copy("Fixtures")]
    ),
]
var products: [Product] = [
    .executable(name: "infinitus-tray", targets: ["InfinitusTray"]),
    .library(name: "InfinitusCore", targets: ["InfinitusCore"]),
]
#if os(macOS)
// Shared SwiftUI components (gauges, burn effects, theme colors) the
// phone app renders too — SwiftUI doesn't exist on Linux, so this stays
// fenced with the AppKit app target above.
targets.append(.target(
    name: "InfinitusUI",
    dependencies: ["InfinitusCore"],
    path: "Sources/InfinitusUI"
))
products.append(.library(name: "InfinitusUI", targets: ["InfinitusUI"]))
targets.append(.executableTarget(
    name: "Infinitus",
    dependencies: ["InfinitusCore", "InfinitusUI"],
    path: "Sources/Infinitus"
))
// Agent-facing control CLI: talks to the running app over its control
// socket (ControlProtocol.swift); bundled into Infinitus.app/Contents/MacOS.
targets.append(.executableTarget(
    name: "InfinitusCLI",
    dependencies: ["InfinitusCore"],
    path: "Sources/InfinitusCLI"
))
products.append(.executable(name: "infinitus", targets: ["InfinitusCLI"]))
#endif

let package = Package(
    name: "Infinitus",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: products,
    targets: targets
)
