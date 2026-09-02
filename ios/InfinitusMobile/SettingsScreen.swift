import SwiftUI
import InfinitusCore
import InfinitusUI

/// The Settings TAB's content (#9 native shell) — the same Form the Mac
/// popup's gear sheet shows, minus any navigation chrome, so both shells
/// present one settings screen.
///
/// The phone's display prefs (#9 phase C2). "Follow Mac" is the whole
/// point of the mirror, so it's on by default and hides everything else;
/// with it off these are the mac's own Display / Themes / Animations
/// choices, same values and same labels.
struct SettingsForm: View {
    @ObservedObject var model: MirrorModel
    /// The QR scanner (#9 remote access) is a sheet, not a screen: it
    /// exists for the ten seconds it takes to pair.
    @State private var scanning = false
    /// Staged text for the "add an address" field — submitting it grows
    /// the endpoint list rather than replacing it (#9 pair once, every
    /// route).
    @State private var newEndpoint = ""

    var body: some View {
        Form {
            Section {
                Toggle("Follow Mac", isOn: $model.followMac)
                Text("Renders exactly what the Mac popup shows — its "
                     + "theme, compact mode, pace fire and intro. Turn "
                     + "off to pick your own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.followMac {
                Section("Theme") {
                    Picker("Theme", selection: $model.localThemeID) {
                        ForEach(model.availableThemes) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    ThemePreviewRow(theme: model.rowTheme)
                }
                Section("Display") {
                    Toggle("Compact popup (one-line accounts, icon controls)",
                           isOn: $model.localCompactRows)
                }
                Section("Pace fire (7d & model bars)") {
                    Picker("Style", selection: $model.localBurnStyle) {
                        Text("Off").tag("off")
                        Text("Ember glow").tag("ember")
                        Text("Flame licks").tag("flame")
                        Text("Limit break").tag("limit")
                    }
                }
                Section("Launch intro") {
                    Picker("Content entrance", selection: $model.localIntroStyle) {
                        Text("Slide from top").tag("top")
                        Text("Slide from bottom").tag("bottom")
                        Text("Fade in").tag("fade")
                        Text("Rows slide from right").tag("rows")
                    }
                    Picker("Title flourish", selection: $model.localIntroTitle) {
                        Text("Zoom bounce").tag("zoom")
                        Text("Stamp slam").tag("slam")
                        Text("Spin up").tag("spin")
                        Text("Off").tag("off")
                    }
                    LabeledContent("Speed") {
                        HStack {
                            Slider(value: $model.localIntroSpeed, in: 0.4...2)
                            Text(String(format: "%.1fx", model.localIntroSpeed))
                                .font(.caption).monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                    Button("Replay intro") { model.replayIntro() }
                }
            }
            // The transport (#9 remote access): which Mac is being
            // mirrored, the token that lets us read it, and the ways in
            // when Bonjour doesn't survive the network.
            Section("Mac connection") {
                Text(model.transportStatus.isEmpty
                     ? "looking for a Mac on this Wi-Fi…"
                     : model.transportStatus)
                    .font(.caption).foregroundStyle(.secondary)
                if PairScanner.isSupported {
                    Button {
                        scanning = true
                    } label: {
                        Label("Scan QR", systemImage: "qrcode.viewfinder")
                    }
                } else {
                    Text("Camera scanning isn't available here (it needs a "
                         + "real device) — type the address and token below.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(model.manualEndpoints.enumerated()), id: \.element) { _, endpoint in
                    Text(endpoint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                .onDelete { model.removeManualEndpoint(at: $0) }
                LabeledContent("Add address") {
                    TextField("host:port, or a tunnel's https:// URL", text: $newEndpoint)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .onSubmit {
                            model.addManualEndpoint(newEndpoint)
                            newEndpoint = ""
                        }
                }
                LabeledContent("Pairing token") {
                    TextField("from the Mac's Devices settings",
                              text: $model.pairToken)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.characters)
                        .font(.system(.body, design: .monospaced))
                }
                Text("Scan the QR in the Mac's Settings → Devices to add every "
                     + "route at once. The token is required — every request "
                     + "carries it, even one to a Mac found automatically. "
                     + "With no address saved the phone falls back to "
                     + "Bonjour on the same Wi-Fi; a saved address is tried "
                     + "first, in the order added, and the one that answers "
                     + "is tried first next time.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            // The 1:1 Mac rendering isn't lost, just off by default
            // (#9 native shell): this flips the whole app back to it.
            Section("Appearance") {
                Toggle("Show as Mac popup", isOn: $model.macPopupView)
                Text("Renders the Mac popup itself — the same layout, "
                     + "chrome and scaling, on dark. Off is the native "
                     + "iOS shell. In Mac view, portrait shows the "
                     + "stacked cards and landscape the wide rows.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $scanning) {
            PairScannerSheet { payload in model.applyPairing(payload) }
        }
    }
}

/// The gear sheet the Mac-popup view puts up — the tab's Form, wrapped
/// in the navigation chrome a sheet needs.
struct SettingsScreen: View {
    @ObservedObject var model: MirrorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsForm(model: model)
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button("Done") { dismiss() }
                }
        }
    }
}

/// What a themed row will look like: the shared gauge with the theme's
/// own window labels and colors — the same components the fleet rows
/// draw, at a glance, while picking.
struct ThemePreviewRow: View {
    let theme: RowTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Preview").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                gauge(label: theme.sessionLabel, color: theme.sessionColor,
                      remaining: 62, dividers: (1..<5).map { Double($0) * 20 })
                gauge(label: theme.weeklyLabel, color: theme.weeklyColor,
                      remaining: 38, dividers: (1..<7).map { Double($0) * 100 / 7 })
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func gauge(label: String, color: String, remaining: Double,
                       dividers: [Double]) -> some View {
        HStack(spacing: 3) {
            Text(PopupGlyph.text(label))
                .font(PopupFont.caption).bold()
                .foregroundStyle(ThemeColor.resolve(color))
            if theme.plain {
                Text("\(Int(100 - remaining))%")
                    .font(PopupFont.caption).monospacedDigit()
            } else {
                GaugeBar(remaining: remaining, color: ThemeColor.resolve(color),
                         dividers: dividers, animated: false)
            }
        }
    }
}
