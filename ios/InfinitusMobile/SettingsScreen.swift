import SwiftUI
import CswapCore
import InfinitusUI

/// The phone's display prefs (#9 phase C2). "Follow Mac" is the whole
/// point of the mirror, so it's on by default and hides everything else;
/// with it off these are the mac's own Display / Themes / Animations
/// choices, same values and same labels.
struct SettingsScreen: View {
    @ObservedObject var model: MirrorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
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
                // The LAN transport (#9): which Mac is being mirrored, and
                // a way in for networks where Bonjour doesn't survive.
                Section("Mac connection") {
                    Text(model.transportStatus.isEmpty
                         ? "looking for a Mac on this Wi-Fi…"
                         : model.transportStatus)
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Address") {
                        TextField("auto (Bonjour)", text: $model.manualEndpoint)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }
                    Text("Leave empty to find the Mac automatically. Set "
                         + "host:port (the Mac's Sync settings show the port) "
                         + "on networks that block Bonjour. Both devices must "
                         + "be on the same Wi-Fi.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Text("Portrait shows the Mac's stacked cards, landscape "
                         + "its wide rows — rotate to switch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Done") { dismiss() }
            }
        }
    }
}
