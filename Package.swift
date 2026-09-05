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
    path: "Sources/Infinitus",
    // Debug only: lets InjectionIII swap top-level/struct functions
    // (docs/guides/hot-reload.md). Release links exactly as before.
    linkerSettings: [.unsafeFlags(["-Xlinker", "-interposable"], .when(configuration: .debug))]
))
// Agent-facing control CLI: talks to the running app over its control
// socket (ControlProtocol.swift); bundled into Infinitus.app/Contents/MacOS.
targets.append(.executableTarget(
    name: "InfinitusCLI",
    dependencies: ["InfinitusCore"],
    path: "Sources/InfinitusCLI"
))
products.append(.executable(name: "infinitusctl", targets: ["InfinitusCLI"]))
#endif
#if os(Windows)
// Pure Win32 settings models and catalog (testable without HWND).
targets.append(.target(
    name: "InfinitusWinUI",
    dependencies: ["InfinitusCore"],
    path: "windows/Sources/InfinitusWinUI",
    linkerSettings: [.linkedLibrary("crypt32"), .linkedLibrary("advapi32")]
))
// Headless mirror daemon (docs/plan-windows/01-stack.md): the same
// InfinitusCore feed/pairing/HTTP contract over Winsock + named pipes.
// Its sources live under windows/, so macOS and Linux never see them.
targets.append(.executableTarget(
    name: "InfinitusWin",
    dependencies: ["InfinitusCore"],
    path: "windows/Sources/InfinitusWin",
    linkerSettings: [.linkedLibrary("ws2_32"), .linkedLibrary("dnsapi"), .linkedLibrary("iphlpapi")]
))
products.append(.executable(name: "infinitus-win", targets: ["InfinitusWin"]))
// Desktop tray: a Win32 notification-area icon over the same core — the
// session list this box already has, without a browser or a phone. No
// shared view code with the Mac (AppKit/SwiftUI don't exist here), so it
// is its own target rather than a port of Sources/Infinitus.
targets.append(.executableTarget(
    name: "InfinitusTrayWin",
    dependencies: ["InfinitusCore", "InfinitusWinUI"],
    path: "windows/Sources/InfinitusTrayWin",
    // dwmapi: immersive dark mode for the panel/settings title bars
    // (WinDarkTitleBar.swift) — DWM draws the non-client area, so a dark
    // client area alone leaves a white caption on top of it.
    linkerSettings: [.linkedLibrary("user32"), .linkedLibrary("shell32"),
                     .linkedLibrary("gdi32"), .linkedLibrary("comctl32"),
                     .linkedLibrary("ws2_32"), .linkedLibrary("iphlpapi"),
                     .linkedLibrary("dwmapi"), .linkedLibrary("crypt32"),
                     .linkedLibrary("comdlg32")]
))
products.append(.executable(name: "infinitus-tray-win", targets: ["InfinitusTrayWin"]))
targets.append(.testTarget(
    name: "InfinitusWinTests",
    dependencies: ["InfinitusWin", "InfinitusWinUI"],
    path: "windows/Tests/InfinitusWinTests"
))
#endif

let package = Package(
    name: "Infinitus",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: products,
    targets: targets
)
