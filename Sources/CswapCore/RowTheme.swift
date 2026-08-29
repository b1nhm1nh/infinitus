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

    public init(
        id: String, name: String, plain: Bool = false,
        sessionLabel: String = "5h", sessionColor: String = "blue",
        weeklyLabel: String = "7d", weeklyColor: String = "red",
        scopedPrefix: String = "", scopedColor: String = "purple",
        creditLabel: String = "$", creditColor: String = "green",
        cashIcon: String = "💰", aheadIcon: String = "sf:flame.fill",
        deadMarker: String = "💀", revivePrefix: String = ""
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
            revivePrefix: try c.decodeIfPresent(String.self, forKey: .revivePrefix) ?? base.revivePrefix
        )
    }

    // MARK: built-ins

    public static let off = RowTheme(
        id: "off", name: "Off — plain numbers", plain: true,
        sessionLabel: "5h", sessionColor: "secondary",
        weeklyLabel: "7d", weeklyColor: "secondary")

    public static let rpg = RowTheme(
        id: "rpg", name: "RPG — HP/MP gauges + gold",
        sessionLabel: "MP", sessionColor: "blue",
        weeklyLabel: "HP", weeklyColor: "red",
        scopedPrefix: "", scopedColor: "purple",
        creditLabel: "$", creditColor: "green",
        cashIcon: "💰", aheadIcon: "sf:flame.circle.fill",
        deadMarker: "💀", revivePrefix: "🧪 ")

    public static let movie = RowTheme(
        id: "movie", name: "Movie — reels & box office",
        sessionLabel: "🎬", sessionColor: "yellow",
        weeklyLabel: "🎞", weeklyColor: "indigo",
        scopedPrefix: "★ ", scopedColor: "orange",
        creditLabel: "🎟", creditColor: "green",
        cashIcon: "💵", aheadIcon: "sf:popcorn.fill",
        deadMarker: "🔚", revivePrefix: "re-release ")

    public static let hades = RowTheme(
        id: "hades", name: "Hades — blades & darkness",
        sessionLabel: "🗡", sessionColor: "red",
        weeklyLabel: "🔱", weeklyColor: "purple",
        scopedPrefix: "🏛 ", scopedColor: "teal",
        creditLabel: "🪙", creditColor: "yellow",
        cashIcon: "💠", aheadIcon: "🔥",
        deadMarker: "☠", revivePrefix: "🩸 ")

    public static let mgs = RowTheme(
        id: "mgs", name: "Metal Gear — tactical espionage",
        sessionLabel: "LIFE", sessionColor: "green",
        weeklyLabel: "PSY", weeklyColor: "cyan",
        scopedPrefix: "⚠ ", scopedColor: "yellow",
        creditLabel: "📦", creditColor: "green",
        cashIcon: "GMP ", aheadIcon: "❗",
        deadMarker: "☠", revivePrefix: "💊 ")

    public static let builtins: [RowTheme] = [off, rpg, movie, hades, mgs]

    // MARK: custom themes

    /// `~/Library/Application Support/CswapBar/themes.json` — a JSON array
    /// of RowTheme objects; only `id` and `name` are required.
    public static func customThemesURL(
        appSupport: URL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> URL {
        appSupport.appendingPathComponent("CswapBar/themes.json")
    }

    /// Best-effort load; a broken file yields [] rather than a crash —
    /// the popup must render with whatever themes are valid.
    public static func loadCustom(from url: URL = customThemesURL()) -> [RowTheme] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([RowTheme].self, from: data)) ?? []
    }

    /// A starter file for "Open themes file" when none exists yet.
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
        "deadMarker": "✖", "revivePrefix": "↻ "
      }
    ]
    """
}
