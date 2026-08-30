import Foundation

/// One popup row "skin": the vocabulary and colors the account grid renders
/// with. Built-ins ship in code; users add their own via a JSON file (see
/// `customThemesURL`) — same shape, decoded with per-field defaults so a
/// minimal `{"id":"x","name":"X"}` is already a valid (plain-ish) theme.
///
/// Colors are strings — a named SwiftUI color ("red", "purple", …) or
/// "#rrggbb" — mapped to real colors in the app layer, so this type stays
/// UI-framework-free and testable.
public struct RowTheme: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Plain style: text percentages, no gauges (the "Off" look).
    public var plain: Bool
    public var sessionLabel: String
    public var sessionColor: String
    public var weeklyLabel: String
    public var weeklyColor: String
    /// Prepended to the model name in scoped cells ("★ " -> "★ Fable").
    public var scopedPrefix: String
    public var scopedColor: String
    public var creditLabel: String
    public var creditColor: String
    /// Leading icon for the estimated-spend cell ("💰1,131").
    public var cashIcon: String
    /// "sf:<symbol>" for an SF Symbol, anything else renders as text/emoji.
    public var aheadIcon: String
    public var deadMarker: String
    /// Prepended to an exhausted window's reset label ("🧪 29m (21:00)").
    public var revivePrefix: String
    /// Verb for a dead limit: "MP down", "🎬 sold out", "LIFE MIA". The
    /// tooltip always carries the plain-English explanation.
    public var deadVerb: String
    /// The all-fresh row's word ("✓ ready"); plain themes keep "ready".
    public var readyLabel: String
    /// Tint for the switch celebration and data-change glow; "" means the
    /// app accent color.
    public var flashColor: String
    /// Per-model rename ("Fable" -> "Dragon"); unmapped models keep their
    /// real name. Tooltips always carry the real name.
    public var modelAlias: [String: String]
    /// Replaces the "Max " in plan strings ("Max 20x" -> "Lv 20x").
    /// "" keeps the plan verbatim.
    public var planPrefix: String
    /// Prepended to the account number ("P" -> "P1").
    public var slotPrefix: String
    /// The live "resetting…" word while a window rolls over
    /// ("respawning…", "recompiling…"); "" keeps "resetting…".
    public var resetWord: String
    /// Next-candidate marker ("🎬" next movie, "▶" plain). "" keeps the
    /// green triangle.
    public var nextIcon: String

    public init(
        id: String, name: String, plain: Bool = false,
        sessionLabel: String = "5h", sessionColor: String = "blue",
        weeklyLabel: String = "7d", weeklyColor: String = "red",
        scopedPrefix: String = "", scopedColor: String = "purple",
        creditLabel: String = "$", creditColor: String = "green",
        cashIcon: String = "💰", aheadIcon: String = "sf:flame.fill",
        deadMarker: String = "💀", revivePrefix: String = "",
        deadVerb: String = "out", readyLabel: String = "ready",
        flashColor: String = "",
        modelAlias: [String: String] = [:],
        planPrefix: String = "",
        slotPrefix: String = "",
        resetWord: String = "",
        nextIcon: String = ""
    ) {
        self.id = id
        self.name = name
        self.plain = plain
        self.sessionLabel = sessionLabel
        self.sessionColor = sessionColor
        self.weeklyLabel = weeklyLabel
        self.weeklyColor = weeklyColor
        self.scopedPrefix = scopedPrefix
        self.scopedColor = scopedColor
        self.creditLabel = creditLabel
        self.creditColor = creditColor
        self.cashIcon = cashIcon
        self.aheadIcon = aheadIcon
        self.deadMarker = deadMarker
        self.revivePrefix = revivePrefix
        self.deadVerb = deadVerb
        self.readyLabel = readyLabel
        self.flashColor = flashColor
        self.modelAlias = modelAlias
        self.planPrefix = planPrefix
        self.slotPrefix = slotPrefix
        self.resetWord = resetWord
        self.nextIcon = nextIcon
    }

    /// Theme name for a model ("Fable" -> "Dragon"); real name otherwise.
    public func modelName(_ name: String?) -> String {
        guard let name else { return "?" }
        return modelAlias[name] ?? name
    }

    /// Themed plan text: "Max 20x" -> planPrefix + "20x".
    public func planLabel(_ plan: String, compact: Bool) -> String {
        let tier = plan.replacingOccurrences(of: "Max ", with: "")
            .replacingOccurrences(of: "Enterprise", with: compact ? "Ent" : "Enterprise")
        if planPrefix.isEmpty { return compact ? tier : plan }
        return planPrefix + tier
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = RowTheme(id: try c.decode(String.self, forKey: .id),
                            name: try c.decode(String.self, forKey: .name))
        self.init(
            id: base.id, name: base.name,
            plain: try c.decodeIfPresent(Bool.self, forKey: .plain) ?? false,
            sessionLabel: try c.decodeIfPresent(String.self, forKey: .sessionLabel) ?? base.sessionLabel,
            sessionColor: try c.decodeIfPresent(String.self, forKey: .sessionColor) ?? base.sessionColor,
            weeklyLabel: try c.decodeIfPresent(String.self, forKey: .weeklyLabel) ?? base.weeklyLabel,
            weeklyColor: try c.decodeIfPresent(String.self, forKey: .weeklyColor) ?? base.weeklyColor,
            scopedPrefix: try c.decodeIfPresent(String.self, forKey: .scopedPrefix) ?? base.scopedPrefix,
            scopedColor: try c.decodeIfPresent(String.self, forKey: .scopedColor) ?? base.scopedColor,
            creditLabel: try c.decodeIfPresent(String.self, forKey: .creditLabel) ?? base.creditLabel,
            creditColor: try c.decodeIfPresent(String.self, forKey: .creditColor) ?? base.creditColor,
            cashIcon: try c.decodeIfPresent(String.self, forKey: .cashIcon) ?? base.cashIcon,
            aheadIcon: try c.decodeIfPresent(String.self, forKey: .aheadIcon) ?? base.aheadIcon,
            deadMarker: try c.decodeIfPresent(String.self, forKey: .deadMarker) ?? base.deadMarker,
            revivePrefix: try c.decodeIfPresent(String.self, forKey: .revivePrefix) ?? base.revivePrefix,
            deadVerb: try c.decodeIfPresent(String.self, forKey: .deadVerb) ?? base.deadVerb,
            readyLabel: try c.decodeIfPresent(String.self, forKey: .readyLabel) ?? base.readyLabel,
            flashColor: try c.decodeIfPresent(String.self, forKey: .flashColor) ?? base.flashColor,
            modelAlias: try c.decodeIfPresent([String: String].self, forKey: .modelAlias) ?? base.modelAlias,
            planPrefix: try c.decodeIfPresent(String.self, forKey: .planPrefix) ?? base.planPrefix,
            slotPrefix: try c.decodeIfPresent(String.self, forKey: .slotPrefix) ?? base.slotPrefix,
            resetWord: try c.decodeIfPresent(String.self, forKey: .resetWord) ?? base.resetWord,
            nextIcon: try c.decodeIfPresent(String.self, forKey: .nextIcon) ?? base.nextIcon
        )
    }

    // MARK: built-ins

    public static let off = RowTheme(
        id: "off", name: "Off — plain numbers", plain: true,
        sessionLabel: "5h", sessionColor: "secondary",
        weeklyLabel: "7d", weeklyColor: "secondary",
        deadMarker: "\u{2715}")   // plain ✕ — the 💀 belongs to the skins (user 2026-08-30)

    public static let rpg = RowTheme(
        id: "rpg", name: "RPG — HP/MP gauges + gold",
        sessionLabel: "MP", sessionColor: "blue",
        weeklyLabel: "HP", weeklyColor: "red",
        scopedPrefix: "⚔ ", scopedColor: "purple",
        creditLabel: "$", creditColor: "green",
        cashIcon: "💰", aheadIcon: "sf:flame.circle.fill",
        deadMarker: "💀", revivePrefix: "🧪 ", deadVerb: "down",
        readyLabel: "full HP", flashColor: "yellow",
        modelAlias: ["Fable": "Dragon", "Opus": "Golem",
                     "Sonnet": "Bard", "Haiku": "Imp"],
        planPrefix: "Lv ", slotPrefix: "P", resetWord: "respawning…", nextIcon: "🎲")

    public static let movie = RowTheme(
        id: "movie", name: "Movie — reels & box office",
        sessionLabel: "🎥", sessionColor: "yellow",
        weeklyLabel: "🎞", weeklyColor: "indigo",
        scopedPrefix: "★ ", scopedColor: "orange",
        creditLabel: "🎟", creditColor: "green",
        cashIcon: "💵", aheadIcon: "sf:speedometer",
        deadMarker: "🔚", revivePrefix: "re-release ", deadVerb: "sold out",
        readyLabel: "now showing", flashColor: "orange",
        modelAlias: ["Fable": "Epic", "Opus": "Blockbuster",
                     "Sonnet": "Indie", "Haiku": "Short"],
        planPrefix: "Studio ", slotPrefix: "🎬", resetWord: "premiering…", nextIcon: "🍿")

    public static let hades = RowTheme(
        id: "hades", name: "Hades — blades & darkness",
        sessionLabel: "🗡", sessionColor: "red",
        weeklyLabel: "🔱", weeklyColor: "purple",
        scopedPrefix: "🏛 ", scopedColor: "teal",
        creditLabel: "🪙", creditColor: "yellow",
        cashIcon: "💠", aheadIcon: "🔥",
        deadMarker: "☠", revivePrefix: "🩸 ", deadVerb: "fallen",
        readyLabel: "unscathed", flashColor: "red",
        modelAlias: ["Fable": "Hydra", "Opus": "Cerberus",
                     "Sonnet": "Fury", "Haiku": "Shade"],
        planPrefix: "Heat ", slotPrefix: "†", resetWord: "raising the dead…", nextIcon: "🕯")

    public static let mgs = RowTheme(
        id: "mgs", name: "Metal Gear — tactical espionage",
        sessionLabel: "LIFE", sessionColor: "green",
        weeklyLabel: "PSY", weeklyColor: "cyan",
        scopedPrefix: "⚠ ", scopedColor: "yellow",
        creditLabel: "📦", creditColor: "green",
        cashIcon: "GMP ", aheadIcon: "❗",
        deadMarker: "☠", revivePrefix: "💊 ", deadVerb: "MIA",
        readyLabel: "all clear", flashColor: "green",
        modelAlias: ["Fable": "FOXHOUND", "Opus": "REX",
                     "Sonnet": "RAY", "Haiku": "Mk.II"],
        planPrefix: "Rank ", slotPrefix: "S", resetWord: "extraction inbound…", nextIcon: "🎯")

    public static let agent = RowTheme(
        id: "agent", name: "AI Agentic — tokens & context",
        sessionLabel: "CTX", sessionColor: "cyan",
        weeklyLabel: "TOK", weeklyColor: "purple",
        scopedPrefix: "🤖 ", scopedColor: "mint",
        creditLabel: "⚡", creditColor: "orange",
        cashIcon: "🪙", aheadIcon: "sf:sparkles",
        deadMarker: "🔌", revivePrefix: "🔁 ", deadVerb: "rate-limited",
        readyLabel: "ready to ship", flashColor: "cyan",
        modelAlias: ["Fable": "frontier", "Opus": "opus-4",
                     "Sonnet": "sonnet-4", "Haiku": "haiku-4"],
        planPrefix: "tier-", slotPrefix: "agent-", resetWord: "rate limit lifting…", nextIcon: "⏭")

    public static let swe = RowTheme(
        id: "swe", name: "Classic SWE — hand-written, no AI",
        sessionLabel: "☕", sessionColor: "orange",
        weeklyLabel: "🗓", weeklyColor: "blue",
        scopedPrefix: "📐 ", scopedColor: "teal",
        creditLabel: "LOC", creditColor: "green",
        cashIcon: "💾", aheadIcon: "sf:flame.fill",
        deadMarker: "🐛", revivePrefix: "hotfix ", deadVerb: "segfaulted",
        readyLabel: "compiles clean", flashColor: "blue",
        modelAlias: ["Fable": "mainframe", "Opus": "kernel",
                     "Sonnet": "daemon", "Haiku": "script"],
        planPrefix: "v", slotPrefix: "#", resetWord: "recompiling…", nextIcon: "⏭")

    public static let scifi = RowTheme(
        id: "scifi", name: "Sci-Fi — warp cores & shields",
        sessionLabel: "PWR", sessionColor: "blue",
        weeklyLabel: "SHLD", weeklyColor: "teal",
        scopedPrefix: "🛸 ", scopedColor: "mint",
        creditLabel: "🔋", creditColor: "green",
        cashIcon: "🪐", aheadIcon: "☄",
        deadMarker: "💥", revivePrefix: "🔧 ", deadVerb: "offline",
        readyLabel: "all systems go", flashColor: "cyan",
        modelAlias: ["Fable": "Mothership", "Opus": "Cruiser",
                     "Sonnet": "Fighter", "Haiku": "Probe"],
        planPrefix: "Class ", slotPrefix: "🚀", resetWord: "recharging…", nextIcon: "📡")

    public static let west = RowTheme(
        id: "west", name: "Wild West — six-guns & gold rush",
        sessionLabel: "🔫", sessionColor: "orange",
        weeklyLabel: "🐴", weeklyColor: "brown",
        scopedPrefix: "🤠 ", scopedColor: "yellow",
        creditLabel: "🏦", creditColor: "green",
        cashIcon: "🥇", aheadIcon: "💨",
        deadMarker: "🪦", revivePrefix: "🌅 ", deadVerb: "six feet under",
        readyLabel: "saddled up", flashColor: "orange",
        modelAlias: ["Fable": "Outlaw", "Opus": "Sheriff",
                     "Sonnet": "Deputy", "Haiku": "Tumbleweed"],
        planPrefix: "Bounty ", slotPrefix: "⭐", resetWord: "sun's rising…", nextIcon: "🌵")

    public static let cyber = RowTheme(
        id: "cyber", name: "Cyberpunk — chrome & neon",
        sessionLabel: "RAM", sessionColor: "#ff2d95",
        weeklyLabel: "NET", weeklyColor: "yellow",
        scopedPrefix: "🦾 ", scopedColor: "cyan",
        creditLabel: "💳", creditColor: "green",
        cashIcon: "💴", aheadIcon: "🧨",
        deadMarker: "💀", revivePrefix: "🧬 ", deadVerb: "flatlined",
        readyLabel: "jacked in", flashColor: "#ff2d95",
        modelAlias: ["Fable": "Netrunner", "Opus": "Militech",
                     "Sonnet": "Ripperdoc", "Haiku": "Gonk"],
        planPrefix: "Cred ", slotPrefix: "◢", resetWord: "rebooting…", nextIcon: "🕶")

    public static let gothic = RowTheme(
        id: "gothic", name: "Gothic — candles & cathedrals",
        sessionLabel: "🦇", sessionColor: "purple",
        weeklyLabel: "🌙", weeklyColor: "indigo",
        scopedPrefix: "⛪ ", scopedColor: "gray",
        creditLabel: "🗝", creditColor: "yellow",
        cashIcon: "⚱", aheadIcon: "🔮",
        deadMarker: "⚰️", revivePrefix: "🌒 ", deadVerb: "entombed",
        readyLabel: "immortal", flashColor: "purple",
        modelAlias: ["Fable": "Vampire Lord", "Opus": "Gargoyle",
                     "Sonnet": "Wraith", "Haiku": "Ghoul"],
        planPrefix: "Crypt ", slotPrefix: "✟", resetWord: "tolling midnight…", nextIcon: "🌹")

    public static let builtins: [RowTheme] = [
        off, rpg, movie, hades, mgs, agent, swe, scifi, west, cyber, gothic]

    // MARK: custom themes

    /// `~/Library/Application Support/Limitless/themes.json` — moved from
    /// the legacy `CswapBar/` dir as part of the one intentional
    /// bundle-id step (2026-08-30). A JSON array of RowTheme objects;
    /// only `id` and `name` are required.
    public static func customThemesURL(
        appSupport: URL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> URL {
        appSupport.appendingPathComponent("Limitless/themes.json")
    }

    /// Best-effort load; a broken file yields [] rather than a crash —
    /// the popup must render with whatever themes are valid. Adopts the
    /// legacy CswapBar/themes.json once, by copy (the old file stays put
    /// so a rollback still finds it).
    public static func loadCustom(from url: URL = customThemesURL()) -> [RowTheme] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            let legacy = url.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("CswapBar/themes.json")
            if fm.fileExists(atPath: legacy.path) {
                try? fm.createDirectory(at: url.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
                try? fm.copyItem(at: legacy, to: url)
            }
        }
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RowTheme].self, from: data)) ?? []
    }

    /// Persist the custom-theme list (community installs write through
    /// this); creates the directory on first use.
    public static func saveCustom(_ themes: [RowTheme],
                                  to url: URL = customThemesURL()) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(themes).write(to: url)
    }

    /// A starter file for "Open themes file" when none exists yet —
    /// every themeable field shown so custom skins see the whole
    /// vocabulary (reconciled with the current struct, 2026-08-30).
    public static let templateJSON = """
    [
      {
        "id": "synthwave",
        "name": "Synthwave — neon grid",
        "sessionLabel": "SUN", "sessionColor": "#ff2d95",
        "weeklyLabel": "GRID", "weeklyColor": "#00e5ff",
        "scopedPrefix": "◆ ", "scopedColor": "#c77dff",
        "creditLabel": "CR", "creditColor": "#39ff14",
        "cashIcon": "🕶", "aheadIcon": "⚡",
        "deadMarker": "✖", "revivePrefix": "↻ ",
        "deadVerb": "offline", "readyLabel": "ONLINE",
        "flashColor": "#ff2d95",
        "modelAlias": {"Fable": "MAINFRAME", "Opus": "SERVER",
                       "Sonnet": "TERMINAL", "Haiku": "CHIP"},
        "planPrefix": "MHz ", "slotPrefix": "▸",
        "resetWord": "rebooting the grid…", "nextIcon": "⏭"
      }
    ]
    """
}
