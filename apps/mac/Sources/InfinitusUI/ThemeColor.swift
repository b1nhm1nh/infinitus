import SwiftUI
import InfinitusCore

/// Maps a theme color string — named or "#rrggbb" — to a SwiftUI Color.
public enum ThemeColor {
    /// Animation accent for a theme — the app accent when unset.
    public static func flash(_ theme: RowTheme) -> Color {
        theme.flashColor.isEmpty ? .accentColor : resolve(theme.flashColor)
    }

    /// `flash(theme)` for a Core Animation layer (LayerEffect hosts take
    /// CGColor, not Color).
    public static func flashCG(_ theme: RowTheme) -> CGColor {
        #if canImport(AppKit)
        return NSColor(flash(theme)).cgColor
        #else
        return UIColor(flash(theme)).cgColor
        #endif
    }

    /// The window's own ground, for the rings and discs that must cut a
    /// gap out of whatever they overlap.
    public static var background: Color {
        #if canImport(AppKit)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(uiColor: .systemBackground)
        #endif
    }

    public static func resolve(_ name: String) -> Color {
        switch name {
        case "red": return .red
        case "blue": return .blue
        case "green": return .green
        case "yellow": return .yellow
        case "orange": return .orange
        case "purple": return .purple
        case "indigo": return .indigo
        case "cyan": return .cyan
        case "teal": return .teal
        case "pink": return .pink
        case "mint": return .mint
        case "brown": return .brown
        case "gray", "secondary": return .secondary
        default:
            guard let c = ThemePalette.hex(name) else { return .primary }
            return Color(red: Double(c.r) / 255,
                         green: Double(c.g) / 255,
                         blue: Double(c.b) / 255)
        }
    }
}
