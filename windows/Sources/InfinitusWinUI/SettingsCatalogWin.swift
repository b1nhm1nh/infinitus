import Foundation
import InfinitusCore

/// Command ID block allocation and pure sidebar data for the Windows Settings shell.
/// No WinSDK imports here so this remains fully testable without HWND.
public enum PaneIDs {
    /// 512 command ids per pane — far more than any pane needs, and the
    /// arithmetic stays readable in a debugger.
    public static let stride: Int32 = 512
    public static let base: Int32 = 0x1000

    public static func block(_ index: Int32) -> Int32 {
        base + index * stride
    }

    public static func paneIndex(for commandID: Int32) -> Int32? {
        guard commandID >= base else { return nil }
        return (commandID - base) / stride
    }
}

public struct PaneDescriptor: Sendable {
    public enum Section: Sendable, Equatable {
        case general
        case engines
    }

    public struct ProviderBadge: Sendable, Equatable {
        public var live: Bool
        public var placeholder: Bool

        public init(live: Bool = false, placeholder: Bool = false) {
            self.live = live
            self.placeholder = placeholder
        }
    }

    public let id: String
    public let title: String
    public let glyph: String
    public let tintRGB: (r: UInt8, g: UInt8, b: UInt8)
    public let keywords: [String]
    public var section: Section
    public var badge: (@Sendable () -> ProviderBadge)?

    public init(
        id: String,
        title: String,
        glyph: String,
        tintRGB: (r: UInt8, g: UInt8, b: UInt8),
        keywords: [String],
        section: Section = .general,
        badge: (@Sendable () -> ProviderBadge)? = nil
    ) {
        self.id = id
        self.title = title
        self.glyph = glyph
        self.tintRGB = tintRGB
        self.keywords = keywords
        self.section = section
        self.badge = badge
    }
}

public enum SettingsCatalogWin {
    /// Pure match against descriptor
    public static func matches(_ descriptor: PaneDescriptor, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        if descriptor.title.range(of: q, options: .caseInsensitive) != nil { return true }
        return descriptor.keywords.contains { $0.range(of: q, options: .caseInsensitive) != nil }
    }

    public static func filter(_ descriptors: [PaneDescriptor], query: String) -> [PaneDescriptor] {
        descriptors.filter { matches($0, query: query) }
    }

    /// Pure scroll range clamping logic
    public static func clampScroll(offset: Int32, contentHeight: Int32, viewportHeight: Int32) -> (offset: Int32, maxOffset: Int32) {
        let maxOffset = max(0, contentHeight - viewportHeight)
        let clamped = min(max(0, offset), maxOffset)
        return (clamped, maxOffset)
    }

    /// Card grid columns calculation
    public static func cardGridColumns(contentWidth: Int32, pad: Int32 = 16, nominalCardWidth: Int32 = 300, gap: Int32 = 10) -> Int32 {
        let availW = max(nominalCardWidth, contentWidth - pad * 2)
        return max(1, (availW + gap) / (nominalCardWidth + gap))
    }

    /// Card grid content height calculation
    public static func cardGridContentHeight(itemCount: Int, columns: Int32, cardHeight: Int32 = 120, gap: Int32 = 10, chromeHeight: Int32 = 240) -> Int32 {
        guard columns > 0 else { return chromeHeight }
        let rows = Int32(ceil(Double(itemCount) / Double(columns)))
        return rows * (cardHeight + gap) + chromeHeight
    }

    // MARK: - Known panes (testable without HWND)

    /// The 17 Windows settings panes. Animations (phase 07) is
    /// deliberately absent. Machine is in the catalog always; the shell
    /// hides it when `WinMachineStore.paneShown` is false, matching the
    /// Mac's `MachineModel.paneShown` gate.
    public static let allDescriptors: [PaneDescriptor] = [
        display, accounts, themes, push, usage, utilization, stats,
        machine, profiles, activity, devices, lock, team, about,
        cswap, cliproxy, nineRouter,
    ]

    public static let display = PaneDescriptor(
        id: "display", title: "Display", glyph: "\u{E7F4}", tintRGB: (150, 90, 220),
        keywords: ["layout", "popup", "size", "compact", "menu bar", "icon", "title", "tray", "tooltip", "preview", "refresh", "autostart", "awake", "balloon"],
        section: .general)
    public static let accounts = PaneDescriptor(
        id: "accounts", title: "Accounts", glyph: "\u{E716}", tintRGB: (52, 152, 219),
        keywords: ["account", "login", "relogin", "token", "add", "remove", "delete", "oauth", "order", "reorder", "alias", "rename"],
        section: .general)
    public static let themes = PaneDescriptor(
        id: "themes", title: "Themes", glyph: "\u{E790}", tintRGB: (230, 140, 40),
        keywords: ["theme", "skin", "gallery", "community", "rpg", "row", "gamification"],
        section: .general)
    public static let push = PaneDescriptor(
        id: "push", title: "Push", glyph: "\u{E95A}", tintRGB: (220, 60, 60),
        keywords: ["slack", "telegram", "webhook", "notification", "push", "away"],
        section: .general)
    public static let usage = PaneDescriptor(
        id: "usage", title: "Usage", glyph: "\u{E9D2}", tintRGB: (50, 190, 90),
        keywords: ["spend", "cost", "tokens", "estimate", "usage", "model", "account"],
        section: .general)
    public static let utilization = PaneDescriptor(
        id: "utilization", title: "Utilization", glyph: "\u{E9D9}", tintRGB: (80, 210, 180),
        keywords: ["history", "utilization", "waste", "window", "5h", "7d", "weekly", "chart", "over time", "run rate", "tokens", "forecast"],
        section: .general)
    public static let stats = PaneDescriptor(
        id: "stats", title: "Stats", glyph: "\u{E9E9}", tintRGB: (108, 92, 231),
        keywords: ["stats", "metrics", "commits", "prs", "lines", "messages", "sessions", "week", "month", "year", "heatmap", "rhythm"],
        section: .general)
    public static let machine = PaneDescriptor(
        id: "machine", title: "Machine", glyph: "\u{E950}", tintRGB: (160, 110, 70),
        keywords: ["machine", "health", "hooks", "runaway", "temp", "swap", "memory", "residue", "guardian", "watch", "cpu", "process"],
        section: .general)
    public static let profiles = PaneDescriptor(
        id: "profiles", title: "Profiles", glyph: "\u{E77B}", tintRGB: (230, 90, 140),
        keywords: ["profile", "preset", "start", "session", "model", "permission", "system prompt", "launch", "folder", "engine", "prompt"],
        section: .general)
    public static let activity = PaneDescriptor(
        id: "activity", title: "Activity", glyph: "\u{E81C}", tintRGB: (60, 180, 180),
        keywords: ["history", "switches", "log", "events", "activity", "switch"],
        section: .general)
    public static let devices = PaneDescriptor(
        id: "devices", title: "Devices", glyph: "\u{E8EA}", tintRGB: (60, 190, 220),
        keywords: ["sync", "settings", "devices", "phone", "iphone", "lan", "companion", "tailscale", "pair", "qr", "export", "import"],
        section: .general)
    public static let lock = PaneDescriptor(
        id: "lock", title: "Lock", glyph: "\u{E72E}", tintRGB: (128, 128, 128),
        keywords: ["lock", "unlock", "privacy", "relock", "timeout", "sleep", "team", "hello", "pin", "password"],
        section: .general)
    public static let team = PaneDescriptor(
        id: "team", title: "Team", glyph: "\u{E902}", tintRGB: (70, 130, 180),
        keywords: ["team", "join", "code", "publish", "roster", "identity", "kid", "invite", "nearby"],
        section: .general)
    public static let about = PaneDescriptor(
        id: "about", title: "About", glyph: "\u{E946}", tintRGB: (100, 95, 220),
        keywords: ["update", "version", "license", "links", "components", "runtime", "daemon", "cswap", "claude"],
        section: .general)
    public static let cswap = PaneDescriptor(
        id: "cswap", title: "cswap", glyph: "\u{E713}", tintRGB: (149, 165, 166),
        keywords: ["engine", "auto switch", "interval", "config", "threshold", "rotate", "claude", "provider", "update", "upgrade", "pypi", "nudge", "resume", "wake", "session"],
        section: .engines)
    public static let cliproxy = PaneDescriptor(
        id: "cliproxy", title: "CLIProxyAPI", glyph: "\u{E839}", tintRGB: (149, 165, 166),
        keywords: ["proxy", "cliproxy", "router", "management", "key", "engine", "provider", "claude"],
        section: .engines)
    public static let nineRouter = PaneDescriptor(
        id: "9router", title: "9Router", glyph: "\u{E72D}", tintRGB: (149, 165, 166),
        keywords: ["9router", "router", "engine", "provider", "claude", "password"],
        section: .engines)
}
