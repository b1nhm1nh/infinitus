// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Infinitus",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure layer: models, feed decoding, supervisor state machine.
        // No AppKit import — everything here runs under `swift test`.
        .target(name: "CswapCore", path: "Sources/CswapCore"),
        .executableTarget(
            name: "Infinitus",
            dependencies: ["CswapCore"],
            path: "Sources/Infinitus"
        ),
        .testTarget(
            name: "CswapCoreTests",
            dependencies: ["CswapCore"],
            path: "Tests/CswapCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
