import SwiftUI
import InfinitusCore

/// Everything Settings search can find. Panes this app owns publish
/// their own rows as `searchEntries`; every pane, owned or not, also
/// contributes its title and the keywords already declared on its
/// `SettingsTab`, so nothing becomes unfindable while the other panes
/// catch up (add one `case` below when they do).
enum SettingsSearchCatalog {
    @MainActor
    static func index(tabs: [SettingsTab]) -> SettingsSearchIndex {
        var entries: [SettingsSearchEntry] = []
        for tab in tabs {
            // The pane itself is always findable by name.
            entries.append(SettingsSearchEntry(pane: tab.title, label: tab.title,
                                               keywords: tab.keywords,
                                               anchor: "\(tab.title)/"))
            entries.append(contentsOf: rows(of: tab.title))
        }
        return SettingsSearchIndex(entries)
    }

    @MainActor
    private static func rows(of pane: String) -> [SettingsSearchEntry] {
        switch pane {
        case "Display": return DisplayPane.searchEntries
        case "Themes": return ThemesPane.searchEntries
        case "Usage": return UsagePane.searchEntries
        case "Utilization": return UtilizationPane.searchEntries
        case "Stats": return StatsPane.searchEntries
        case "Machine": return MachinePane.searchEntries
        case "Activity": return ActivityPane.searchEntries
        case LockModel.paneTitle: return LockPane.searchEntries
        case "About": return AboutPane.searchEntries
        // Accounts, Push, Profiles, Devices, Team and the engine panes
        // carry their title and keywords only, until they publish their
        // own searchEntries.
        default: return []
        }
    }
}

/// The section a search hit asked for. A pane's Section reads it and
/// flashes once when it is the one; nothing else in the app reads it.
private struct SettingsHighlightKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var settingsHighlight: String? {
        get { self[SettingsHighlightKey.self] }
        set { self[SettingsHighlightKey.self] = newValue }
    }
}

extension View {
    /// Marks a Section as a search destination: `scrollTo` can find it
    /// by this id, and it flashes once when a search hit points at it.
    func settingsAnchor(_ id: String) -> some View {
        modifier(SettingsAnchor(anchor: id))
    }
}

private struct SettingsAnchor: ViewModifier {
    let anchor: String
    @Environment(\.settingsHighlight) private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lit: Bool { highlight == anchor }

    func body(content: Content) -> some View {
        content
            .id(anchor)
            // nil, not a clear fill: in a grouped Form the section's
            // card IS its row backgrounds, so a permanent
            // listRowBackground would strip the card off every
            // anchored section.
            .listRowBackground(lit
                ? RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.18))
                : nil)
            // One shot, ~0.35s, cleared by the caller after 1.2s: no
            // repeatForever, no TimelineView, nothing ticking (repo
            // rule — idle CPU stays ~0%).
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: lit)
    }
}
