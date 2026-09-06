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
    @AppStorage("chat_header") private var chatHeader = "compact"
    @AppStorage(FleetAlarmCenter.enabledKey) private var fleetAlarms = true

    @ObservedObject var model: MirrorModel
    /// The Team tab's biometric lock (spec §2.2), so the toggle's label
    /// can name whatever this phone actually has.
    @ObservedObject private var lock = MobileLock.shared
    /// The QR scanner (#9 remote access) is a sheet, not a screen: it
    /// exists for the ten seconds it takes to pair.
    @State private var scanning = false
    /// Staged text for the "add an address" field — submitting it grows
    /// the endpoint list rather than replacing it (#9 pair once, every
    /// route).
    @State private var newEndpoint = ""
    /// The Form's own edit mode. EditButton toggles the whole
    /// NavigationStack's, so the Addresses header has to keep showing
    /// it while editing is on: deleting the last address would
    /// otherwise hide the Done button and leave every row in the Form
    /// unresponsive with no way back out.
    @Environment(\.editMode) private var editMode
    @State private var paired = false
    /// The other Mac a "Make primary" tap is confirming (#144 phase 1).
    @State private var promoting: MirrorModel.OtherMac?
    /// The Mac a swipe is asking to forget (critique [P1]: the
    /// destructive action was the unconfirmed one).
    @State private var forgetting: MirrorModel.OtherMac?
    /// The pairing token is a bearer credential for the whole fleet, so
    /// it is covered until its owner asks to see it.
    @State private var tokenShown = false

    var body: some View {
        Form {
            // The transport leads: with nothing paired the only thing
            // that makes this app work is the first thing on screen,
            // and the cosmetics wait below it (critique, iOS
            // hierarchy: "on a phone with nothing paired, the first
            // screen is a theme picker").
            connectionSection
            addressesSection
            // A token cleared out of the field below must not hide the
            // Macs it can't forget: the other Macs are stored on their
            // own, so the group stays as long as one of them is there.
            if isPaired || !model.others.isEmpty { otherMacsSection }
            appearanceSection
            if !model.followMac {
                themeSection
                motionSection
            }
            chatHeaderSection
            DictationSettings()
            ScreenshotSettings()
            notificationsSection
            teamSection
            AboutSettings(model: model)
        }
        .onChange(of: fleetAlarms) { _, on in
            if !on { FleetAlarmCenter.shared.clearPending() }
        }
        .sheet(isPresented: $scanning) {
            PairScannerSheet { payload in
                if model.applyPairing(payload) { paired = true }
            }
        }
        .alert("Paired", isPresented: $paired) {
            Button("OK") { model.requestedTab = "fleet" }
        } message: {
            Text("Paired with \(model.snapshot?.machineName ?? "the Mac"). Its accounts are on the Fleet tab.")
        }
        .sensoryFeedback(.success, trigger: paired)
        .confirmationDialog("Make Primary",
                            isPresented: Binding(get: { promoting != nil }, set: { if !$0 { promoting = nil } }),
                            presenting: promoting) { other in
            Button("Make Primary") { model.makePrimary(id: other.id) }
            Button("Cancel", role: .cancel) {}
        } message: { other in
            Text("Make \(other.pairing.name) the primary Mac? Chats, approvals, widgets and Live Activities follow it.")
        }
        .confirmationDialog("Forget This Mac?",
                            isPresented: Binding(get: { forgetting != nil },
                                                 set: { if !$0 { forgetting = nil } }),
                            presenting: forgetting) { other in
            Button("Forget \(other.pairing.name)", role: .destructive) {
                model.forgetOther(id: other.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: { other in
            Text("This phone stops seeing \(other.pairing.name)'s fleet and sessions. The Mac itself is untouched — scan its QR code again to add it back.")
        }
    }

    /// A token is what a pairing IS — with none, nothing this screen
    /// offers below the fold can work yet.
    private var isPaired: Bool { !model.pairToken.isEmpty }

    /// The transport's own words while it looks, or the theme's
    /// ("Scouting for the Mac…" under RPG) before it has any.
    private var statusText: String {
        model.transportStatus.isEmpty
            ? model.rowTheme.loadingWord("searching")
            : model.transportStatus
    }

    private var scanButton: some View {
        Button { scanning = true } label: {
            Label("Scan the Mac's QR Code", systemImage: "qrcode.viewfinder")
        }
    }

    // MARK: - the transport

    /// Which Mac is mirrored and the credential that reads it. Unpaired,
    /// the section IS the onboarding step and leads with the scan;
    /// paired, the status leads and the scan drops to a plain row.
    private var connectionSection: some View {
        Section {
            if !isPaired, PairScanner.isSupported {
                scanButton.font(.body.weight(.semibold))
            }
            LabeledContent("Status", value: statusText)
            if isPaired, PairScanner.isSupported { scanButton }
            LabeledContent("Pairing token") {
                HStack(spacing: 8) {
                    Group {
                        if tokenShown {
                            TextField("Paste or scan", text: $model.pairToken)
                        } else {
                            SecureField("Paste or scan", text: $model.pairToken)
                        }
                    }
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(.body, design: .monospaced))
                    Button {
                        tokenShown.toggle()
                    } label: {
                        Image(systemName: tokenShown ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(tokenShown ? "Hide the pairing token" : "Show the pairing token")
                    .accessibilityHint("The token lets this phone read the Mac's fleet.")
                }
            }
        } header: {
            Text(isPaired ? "Mac connection" : "Pair with a Mac")
        } footer: {
            Text(connectionFooter)
        }
    }

    private var connectionFooter: String {
        let camera = PairScanner.isSupported
            ? "Open Settings › Devices on the Mac and scan the code it shows — it fills in the address and the token for you."
            : "This phone has no camera to scan with: copy the address and the token from Settings › Devices on the Mac."
        return isPaired
            ? camera + " On the same Wi-Fi the phone finds the Mac by itself."
            : camera
    }

    /// Where to reach the Mac when Bonjour can't: one row per address,
    /// deletable in edit mode or by a swipe.
    private var addressesSection: some View {
        Section {
            ForEach(model.manualEndpoints, id: \.self) { endpoint in
                Text(endpoint)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel("Address \(endpoint)")
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
        } header: {
            HStack {
                Text("Addresses")
                Spacer()
                if !model.manualEndpoints.isEmpty || editMode?.wrappedValue.isEditing == true {
                    EditButton()
                        .font(.footnote.weight(.semibold))
                        .textCase(nil)
                }
            }
        } footer: {
            Text("The phone finds the Mac on this Wi-Fi by itself. Add an address to reach it from anywhere else — a tunnel's URL works from any network.")
        }
    }

    /// Every OTHER paired Mac (#144 phase 1): read-only fleets and
    /// sessions elsewhere in the app, forgettable or promotable here.
    private var otherMacsSection: some View {
        Section {
            ForEach(model.others) { other in
                VStack(alignment: .leading, spacing: 2) {
                    Text(other.pairing.name).fontWeight(.semibold)
                    Text(otherCaption(other)).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .swipeActions {
                    Button("Forget", role: .destructive) { forgetting = other }
                }
                .contextMenu {
                    Button("Make Primary") { promoting = other }
                }
            }
        } header: {
            Text("Other Macs")
        } footer: {
            Text("Scan another Mac's QR code to add it. Only the primary Mac gets chats, approvals, widgets and Live Activities in this version.")
        }
    }

    // MARK: - what the app looks like

    private var appearanceSection: some View {
        Section {
            Toggle("Follow Mac", isOn: $model.followMac)
            Toggle("Show as Mac popup", isOn: $model.macPopupView)
        } header: {
            Text("Appearance")
        } footer: {
            Text("Follow Mac renders exactly what the Mac popup shows — its theme, rows, pace fire and intro; turn it off to choose your own here. Show as Mac popup renders the popup itself instead of the iPhone layout: portrait stacks the cards, landscape shows the wide rows.")
        }
    }

    private var themeSection: some View {
        Section {
            NavigationLink {
                ThemeChooserScreen(selection: $model.localThemeID,
                                   themes: model.availableThemes)
            } label: {
                LabeledContent("Theme") {
                    HStack(spacing: 8) {
                        ThemeSwatch(theme: localTheme)
                        Text(localTheme.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            Toggle("Compact rows", isOn: $model.localCompactRows)
        } header: {
            Text("Theme")
        } footer: {
            Text("A theme renames the tabs, the gauges, the status words and the fleet's own names, and gives them its colours. Compact rows put one account on a line.")
        }
    }

    /// The theme this PHONE is set to. `model.rowTheme` answers with the
    /// Mac's while Follow Mac is on; this section only shows with it off,
    /// but the row must never read from the Mac's choice.
    private var localTheme: RowTheme {
        model.availableThemes.first { $0.id == model.localThemeID } ?? .off
    }

    private var motionSection: some View {
        Section {
            NavigationLink {
                PaceFireChooser(selection: $model.localBurnStyle, theme: localTheme)
            } label: {
                LabeledContent("Pace fire", value: Self.paceFireNames[model.localBurnStyle] ?? "Off")
            }
            NavigationLink {
                ContentEntranceChooser(selection: $model.localIntroStyle)
            } label: {
                LabeledContent("Content entrance", value: Self.entranceNames[model.localIntroStyle] ?? "Fade in")
            }
            NavigationLink {
                TitleFlourishChooser(selection: $model.localIntroTitle, theme: localTheme)
            } label: {
                LabeledContent("Title flourish", value: Self.flourishNames[model.localIntroTitle] ?? "Off")
            }
            LabeledContent("Speed") {
                HStack(spacing: 8) {
                    Slider(value: $model.localIntroSpeed, in: 0.4...2)
                        .accessibilityLabel("Intro speed")
                    Text(String(format: "%.1f×", model.localIntroSpeed))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            Button("Replay Intro") { model.replayIntro() }
        } header: {
            Text("Motion")
        } footer: {
            Text("Pace fire sets the weekly and model bars alight when an account spends faster than the clock. The intro plays once when the app opens: the content enters, the bars fill, then the title lands.")
        }
    }

    /// The value each Motion row shows — the chooser's own names, so the
    /// row and the pushed screen never disagree.
    private static let paceFireNames = ["off": "Off", "ember": "Ember glow",
                                        "flame": "Flame licks", "limit": "Limit break"]
    private static let entranceNames = ["top": "Slide from top", "bottom": "Slide from bottom",
                                        "fade": "Fade in", "rows": "Rows slide from right"]
    private static let flourishNames = ["zoom": "Zoom bounce", "slam": "Stamp slam",
                                        "spin": "Spin up", "off": "Off"]

    private var chatHeaderSection: some View {
        Section {
            ChatHeaderPicker(selection: $chatHeader, theme: model.rowTheme)
        } header: {
            Text("Chat header")
        } footer: {
            Text("What a session's chat wears above the transcript.")
        }
    }

    // MARK: - the rest

    private var notificationsSection: some View {
        Section {
            Toggle("Reset and swap alerts", isOn: $fleetAlarms)
        } header: {
            Text("Notifications")
        } footer: {
            Text("The phone raises these itself from the last snapshot, with nothing needed on the Mac: an exhausted account's limit lifting in ten minutes, and the account the fleet has just swapped to.")
        }
    }

    private var teamSection: some View {
        Section {
            Toggle("Lock the Team tab with \(lock.methodName)", isOn: $lock.enabled)
        } header: {
            Text("Team")
        } footer: {
            Text("Joining a team from this phone needs the lock on; the Mac has the same rule.")
        }
    }

    /// Settings › Devices' caption for an other Mac: what it's showing,
    /// or the mirror's own status line while it hasn't answered yet.
    private func otherCaption(_ other: MirrorModel.OtherMac) -> String {
        guard other.snapshot != nil else {
            return other.status.isEmpty ? "Looking for this Mac…" : other.status
        }
        let sessions = other.fleets.reduce(0) { $0 + ($1.liveSessions?.total ?? 0) }
        return "\(other.fleets.count) fleet\(other.fleets.count == 1 ? "" : "s") · "
            + "\(sessions) session\(sessions == 1 ? "" : "s")"
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

/// Dictation language and what happens to a non-English take (user
/// 2026-09-04: "can it accept Vietnamese? … build them configurable").
private struct DictationSettings: View {
    @AppStorage(Dictation.localeKey) private var localeID = ""
    @AppStorage(Dictation.policyKey) private var policy = "phone"
    @AppStorage(Dictation.hintsKey) private var hints = true

    private var phoneTranslation: Bool {
        if #available(iOS 18.0, *) { return true } else { return false }
    }

    var body: some View {
        Section {
            Picker("Language", selection: $localeID) {
                Text("Phone language (\(Dictation.displayName(Locale.current)))").tag("")
                ForEach(Dictation.supportedLocales, id: \.identifier) { locale in
                    Text(Dictation.displayName(locale)).tag(locale.identifier)
                }
            }
            .pickerStyle(.navigationLink)
            Picker("Non-English dictation", selection: $policy) {
                if phoneTranslation { Text("Translate on the phone").tag("phone") }
                Text("Send as spoken, ask for an English reply").tag("note")
                Text("Send as spoken").tag("none")
            }
            Toggle("Hint the session's terms", isOn: $hints)
        } header: {
            Text("Dictation")
        } footer: {
            Text((phoneTranslation
                  ? "Translation runs on the phone — nothing leaves it; the first use downloads the language. "
                  : "On-phone translation needs iOS 18. ")
                 + "Long-press the mic to switch language. Hints hand the recognizer the "
                 + "session's names, branch and tools so English terms survive a "
                 + (localeID.isEmpty ? "non-English" : Dictation.displayName(Locale(identifier: localeID)))
                 + " take.")
        }
    }
}

/// Screenshots offered for one-tap sending (user 2026-09-04: "react
/// system screenshots too as I may take screenshots from other apps").
private struct ScreenshotSettings: View {
    @AppStorage(ScreenshotWatch.enabledKey) private var offerScreenshots = true

    var body: some View {
        Section {
            Toggle("Offer new screenshots", isOn: $offerScreenshots)
                .onChange(of: offerScreenshots) { _, on in
                    ScreenshotWatch.enabled = on
                    if on { Task { await ScreenshotWatch().requestAccess() } }
                }
        } header: {
            Text("Screenshots")
        } footer: {
            Text("A screenshot you take — in this app or any other — is offered on a session's chat "
                 + "for one-tap sending. Needs full Photos access. Without it: the camera button in a "
                 + "chat's header sends that screen, and a shake on any screen captures it and asks "
                 + "which session to send it to.")
        }
    }
}

/// Both apps' versions, and the Mac's own update — one tap from the
/// phone, brew doing the actual upgrade (#121).
private struct AboutSettings: View {
    @ObservedObject var model: MirrorModel
    @State private var confirming = false
    @State private var updating = false
    @State private var result: String?

    private var phoneVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
    private var phoneBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    var body: some View {
        Section("About") {
            LabeledContent("This iPhone", value: "Infinitus \(phoneVersion) (\(phoneBuild))")
            if let snapshot = model.snapshot {
                if let app = snapshot.app {
                    LabeledContent(snapshot.machineName,
                                  value: "Infinitus \(app.version) · \(app.sha.prefix(7))")
                    if app.updateChannel == "source" {
                        Text("source build — update from the repo")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let updateVersion = app.updateVersion {
                        LabeledContent("Mac update available: \(updateVersion)") {
                            Button("Update the Mac") { confirming = true }
                                .disabled(updating)
                        }
                        .confirmationDialog("Update the Mac to \(updateVersion)? brew upgrades "
                                             + "Infinitus and relaunches it.",
                                            isPresented: $confirming, titleVisibility: .visible) {
                            Button("Update") { update() }
                        }
                        if let result {
                            Text(result).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let phoneLatest = app.phoneLatest,
                       let latest = PackageVersion(phoneLatest), let mine = PackageVersion(phoneVersion),
                       mine < latest {
                        Text("A newer Infinitus (\(phoneLatest)) is out — rebuild the phone app from the release.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    LabeledContent(snapshot.machineName, value: "version not reported")
                }
            } else {
                LabeledContent("Mac", value: "not connected")
            }
        }
    }

    private func update() {
        updating = true
        result = nil
        Task {
            do {
                let reply = try await NetworkFleetMirror.shared.updateMac()
                result = reply.detail ?? reply.outcome
            } catch {
                result = error.localizedDescription
            }
            updating = false
        }
    }
}
