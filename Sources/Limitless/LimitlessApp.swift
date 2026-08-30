import SwiftUI
import AppKit
import CswapCore

/// The one AppKit knob that lets a popover-only accessory app live with no
/// open windows: without it, SwiftUI terminates the process as soon as the
/// last window closes (verified live — the app died the moment the keepalive
/// window was closed OR ordered out).
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Injected by LimitlessApp.init; the status item is created HERE, in
    // applicationDidFinishLaunching — creating an NSStatusItem before the
    // app finishes launching fails silently (no item, no error).
    var makeStatusItem: (() -> Void)?
    var statusHolder: StatusItemHolder?

    func applicationDidFinishLaunching(_ notification: Notification) {
        makeStatusItem?()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool {
        false
    }

    /// `open Limitless.app` on an already-running instance lands here: show
    /// the pinned window. This is the guaranteed way into the UI when the
    /// menu bar is too full to display the status item at all.
    func applicationShouldHandleReopen(_ app: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        statusHolder?.controller.showPinnedWindow()
        return false
    }
}

@main
struct LimitlessApp: App {
    @StateObject private var model: AppModel
    @StateObject private var settingsModel: SettingsModel
    @StateObject private var reliabilityModel: ResumeReliabilityModel
    @StateObject private var notifyModel: NotifyModel
    @StateObject private var usageModel: UsageModel
    @StateObject private var updateModel: UpdateModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Menu bar app: no Dock icon, no main window.
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        let settingsModel = SettingsModel(cli: model.cli)
        _settingsModel = StateObject(wrappedValue: settingsModel)
        let notifyModel = NotifyModel(cli: model.cli)
        _notifyModel = StateObject(wrappedValue: notifyModel)
        let usage = UsageModel(cli: model.cli)
        _usageModel = StateObject(wrappedValue: usage)
        let update = UpdateModel(cli: model.cli)
        _updateModel = StateObject(wrappedValue: update)
        update.restartEngine = { [weak model] in model?.restartEngine() }
        update.startAutoCheck()
        let reliabilityModel = ResumeReliabilityModel()
        _reliabilityModel = StateObject(wrappedValue: reliabilityModel)
        // Warm the multi-second transcript scan at launch so the Usage tab
        // and the gamified gold column open onto data, not a spinner.
        usage.loadIfNeeded()
        appDelegate.makeStatusItem = { [weak appDelegate] in
            appDelegate?.statusHolder = StatusItemHolder(
                model: model, usage: usage,
                settingsTabs: {
                    settingsTabs(
                        model: model, settingsModel: settingsModel,
                        reliabilityModel: reliabilityModel,
                        notifyModel: notifyModel, usageModel: usage,
                        updateModel: update)
                })
        }
        model.startFeeds()
        // Deferred past didFinishLaunching: requesting in App.init — before
        // the app is registered with Notification Center — fails with
        // "Notifications are not allowed for this application".
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            Notifier.requestAuthorization()
        }
        Task { await model.refreshSnapshot() }
    }

    var body: some Scene {
        // No MenuBarExtra scene: the status item is a raw NSStatusItem owned
        // by StatusItemController (see its header for why). Keep-alive with
        // zero windows comes from KeepAliveDelegate.

        Settings {
            SettingsRoot(tabs: settingsTabs(
                model: model, settingsModel: settingsModel,
                reliabilityModel: reliabilityModel,
                notifyModel: notifyModel, usageModel: usageModel,
                updateModel: updateModel))
        }
    }
}

/// The settings panes, declared once. The Settings scene (the standard
/// app-menu path, unreachable for an accessory app with no app menu)
/// renders them as a SwiftUI TabView; the controller-owned window the
/// popup's Settings… button opens renders them as an AppKit
/// NSTabViewController(tabStyle: .toolbar) — the REAL icon-toolbar
/// Settings look, which no public SwiftUI TabViewStyle reproduces.
func settingsTabs(
    model: AppModel, settingsModel: SettingsModel,
    reliabilityModel: ResumeReliabilityModel,
    notifyModel: NotifyModel, usageModel: UsageModel,
    updateModel: UpdateModel
) -> [SettingsTab] {
    [
        SettingsTab(title: "cswap", symbol: "gearshape", tint: .gray,
                    keywords: ["engine", "auto switch", "interval", "config",
                               "threshold", "rotate"],
                    view: AnyView(SettingsPane(model: settingsModel))),
        SettingsTab(title: "Resume reliability", symbol: "arrow.clockwise", tint: .blue,
                    keywords: ["session", "nudge", "wake", "stop"],
                    view: AnyView(ResumeReliabilityPane(model: reliabilityModel))),
        SettingsTab(title: "Display", symbol: "menubar.rectangle", tint: .purple,
                    keywords: ["theme", "layout", "popup", "size", "compact",
                               "menu bar", "icon", "order", "alias"],
                    view: AnyView(DisplayPane(model: model))),
        SettingsTab(title: "Sync", symbol: "icloud", tint: .cyan,
                    keywords: ["icloud", "sync", "settings", "drive", "devices"],
                    view: AnyView(SyncPane(sync: model.sync))),
        SettingsTab(title: "Activity", symbol: "clock.arrow.circlepath", tint: .teal,
                    keywords: ["history", "switches", "log", "events"],
                    view: AnyView(ActivityPane(model: model))),
    ]
    + (model.debugMenu
       ? [SettingsTab(title: "Animations", symbol: "sparkles", tint: .pink,
                      keywords: ["debug", "test"],
                      view: AnyView(AnimationsDebugPane(model: model)))]
       : [])
    + [
        SettingsTab(title: "Push", symbol: "antenna.radiowaves.left.and.right",
                    tint: .red,
                    keywords: ["slack", "telegram", "webhook", "notification"],
                    view: AnyView(NotifyPane(model: notifyModel, app: model))),
        SettingsTab(title: "Usage", symbol: "chart.bar", tint: .green,
                    keywords: ["spend", "cost", "tokens", "estimate"],
                    view: AnyView(UsagePane(model: usageModel))),
        SettingsTab(title: "About", symbol: "info.circle", tint: .indigo,
                    keywords: ["update", "version", "license", "links"],
                    view: AnyView(AboutPane(model: updateModel))),
    ]
}

/// CodexBar-style settings shell: a searchable sidebar of icon-tile rows
/// on the left, the selected pane on the right.
struct SettingsRoot: View {
    let tabs: [SettingsTab]
    @State private var selection: String?
    @State private var query = ""

    private var filtered: [SettingsTab] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return tabs }
        return tabs.filter { tab in
            tab.title.localizedCaseInsensitiveContains(q)
                || tab.keywords.contains { $0.localizedCaseInsensitiveContains(q) }
        }
    }
    private var current: SettingsTab? {
        tabs.first { $0.title == selection } ?? tabs.first
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(filtered, id: \.title) { tab in
                    HStack(spacing: 8) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(tab.tint.gradient))
                        Text(tab.title)
                    }
                    .tag(tab.title)
                }
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search settings")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            if let tab = current {
                tab.view.navigationTitle(tab.title)
            }
        }
        .frame(minWidth: 700, minHeight: 480)
        .onAppear { if selection == nil { selection = tabs.first?.title } }
    }
}

/// The "Limitless" strip: app icon + name, tinted by the active theme
/// (user request 2026-08-30). The pop-out wears it as its drag-strip
/// title; the full popover shows it above the rows.
struct LimitlessHeader: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 5) {
            icon
                .frame(width: 16, height: 16)
            Text("Limitless")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity)
    }

    /// Unbundled runs (run-unbundled.sh) have no AppIcon, so
    /// applicationIconImage is the generic document icon — use the
    /// menu bar glyph, tinted like the title, instead.
    @ViewBuilder private var icon: some View {
        if Bundle.main.bundlePath.hasSuffix(".app"),
           let appIcon = NSApp.applicationIconImage {
            Image(nsImage: appIcon).resizable()
        } else {
            Image(nsImage: MenuBarGlyph.image)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint)
        }
    }

    private var tint: Color {
        let theme = model.rowTheme
        if theme.plain || theme.id == "off" { return .secondary }
        return theme.flashColor.isEmpty ? .accentColor
                                        : ThemeColor.resolve(theme.flashColor)
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageModel
    /// False in the pop-out: PinnedRoot already wears the header as its
    /// drag strip, and two of them would stack.
    var showHeader = true
    @ObservedObject private var status = ServiceStatusModel.shared

    var body: some View {
        Group {
            if model.compactRows {
                // Compact adapts to the fleet size: a couple of accounts
                // get a horizontal icon strip under the rows (a vertical
                // rail would dwarf them); more get a two-column icon rail
                // (seven stacked icons out-grew five rows and left dead
                // space below — the rail must never drive the height).
                if model.accounts.count <= 3 {
                    VStack(alignment: .leading, spacing: 8) {
                        accountArea
                        errorLines
                        HStack(spacing: 12) { compactControls }
                            .buttonStyle(.borderless)
                    }
                } else {
                    HStack(alignment: .top, spacing: 8) {
                        LazyVGrid(columns: [GridItem(.fixed(20), spacing: 10),
                                            GridItem(.fixed(20))],
                                  spacing: 10) {
                            compactControls
                        }
                        .frame(width: 52)
                        .buttonStyle(.borderless)
                        VStack(alignment: .leading, spacing: 8) {
                            accountArea
                            errorLines
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    // Compact mode stays headerless on purpose — it exists
                    // to be tiny.
                    if showHeader { LimitlessHeader(model: model) }
                    accountArea
                    errorLines
                    Divider()
                    // One footer row (user request 2026-08-30, was two):
                    // actions leading, app chrome after, status chips
                    // trailing. "Test notification" retired — the Push
                    // pane keeps its own test button. Stacked layout gets
                    // icon-only buttons: the titled row out-widened the
                    // narrow cards and the footer drove the popup width
                    // (cards stretched to fill, 2026-08-30 screenshot).
                    HStack {
                        Button {
                            model.rotate()
                        } label: {
                            Label("Rotate", systemImage: "arrow.2.circlepath")
                        }
                        .help("Switch to the next account in rotation")
                        Button {
                            Task { await model.refreshSnapshot() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .help("Refresh account usage now")
                        Button {
                            model.showSettings?()
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        Button {
                            model.popoverPinned.toggle()
                        } label: {
                            Label(model.popoverPinned ? "Unpin" : "Pin",
                                  systemImage: model.popoverPinned ? "pin.fill" : "pin")
                        }
                        .help("Pin keeps this popup open when you click elsewhere; "
                              + "the menu bar icon still closes it.")
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                model.compactRows.toggle()
                            }
                        } label: {
                            Label("Compact", systemImage: "rectangle.compress.vertical")
                        }
                        .help("Hide actions, event log, and history")
                        layoutToggleIcon
                        popOutIcon
                        Spacer()
                        serviceChip
                        agentChip
                        engineBadge
                        if model.appUpdatePending {
                            Button {
                                model.relaunchApp()
                            } label: {
                                Label("Restart to update",
                                      systemImage: "arrow.triangle.2.circlepath")
                                    .foregroundStyle(.orange)
                            }
                            .help("A newer build is on disk")
                        }
                        Button {
                            model.shutdown()   // engine stops first
                        } label: {
                            Label("Quit", systemImage: "power")
                        }
                        .help("Quit")
                    }
                    .labelStyle(AnyLabelStyle(model.popupLayout == "stacked"
                                              ? AnyLabelStyle(.iconOnly)
                                              : AnyLabelStyle(.titleAndIcon)))
                }
            }
        }
        .padding(model.compactRows ? 8 : 10)
        // No minWidth in compact: full mode's 560 floor was sticking
        // through the switch and padding the popup out sideways
        // (user-reported overflow after full->compact).
        .frame(minWidth: model.compactRows ? nil : 560)
        .animation(.easeInOut(duration: 0.3), value: model.compactRows)
        .animation(.easeInOut(duration: 0.3), value: model.gamification)
        // Real scaling, not dynamicTypeSize: macOS ignores Dynamic Type,
        // so the popup renders at 1x and scaleEffect + a matching frame
        // grow both the pixels AND the popover's fitting size.
        .modifier(PopupScale(scale: model.popupScale))
        .onAppear { status.refreshIfStale() }
        // Click-to-switch asks first (user request): rows only STAGE the
        // target; this alert commits it.
        .alert(
            "Switch account?",
            isPresented: Binding(
                get: { model.pendingSwitch != nil },
                set: { if !$0 { model.pendingSwitch = nil } })
        ) {
            Button("Switch") {
                if let n = model.pendingSwitch { model.switchTo(n) }
                model.pendingSwitch = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every Claude Code session on this machine rides the "
                 + "active account. Switch to account "
                 + "\(model.pendingSwitch.map(String.init) ?? "?")?")
        }
    }

    /// Ten-plus accounts scroll instead of growing an off-screen popup.
    @ViewBuilder private var accountArea: some View {
        if model.accounts.count > 10 {
            ScrollView(showsIndicators: false) {
                AccountRows(model: model, usage: usage)
            }
            .frame(maxHeight: 560)
        } else {
            AccountRows(model: model, usage: usage)
        }
    }

    /// The compact-mode controls, container-agnostic: the caller decides
    /// rail grid vs horizontal strip.
    @ViewBuilder private var compactControls: some View {
        Button { model.showSettings?() } label: {
            Image(systemName: "gearshape")
        }
        .help("Settings")
        Button { model.popoverPinned.toggle() } label: {
            Image(systemName: model.popoverPinned ? "pin.fill" : "pin")
        }
        .help("Pin keeps this popup open when you click elsewhere")
        Button { model.compactRows.toggle() } label: {
            Image(systemName: "rectangle.expand.vertical")
        }
        .help("Show actions and the full footer")
        layoutToggleIcon
        popOutIcon
        serviceDot
        agentChip
        if model.appUpdatePending {
            Button { model.relaunchApp() } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            }
            .help("A newer build is on disk — restart to update")
        }
        engineBadgeIcon
        Button { model.shutdown() } label: {
            Image(systemName: "power")
        }
        .help("Quit")
    }

    /// Quick wide-rows <-> stacked-cards flip, mirroring the Display
    /// pane's "Popup layout" picker.
    private var layoutToggleIcon: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) {
                model.popupLayout = model.popupLayout == "stacked" ? "wide" : "stacked"
            }
        } label: {
            Image(systemName: model.popupLayout == "stacked"
                  ? "rectangle.split.2x1" : "rectangle.split.1x2")
        }
        .help(model.popupLayout == "stacked"
              ? "Switch to wide rows" : "Switch to stacked cards")
    }

    @ViewBuilder private var errorLines: some View {
        if let err = model.lastError {
            Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }

    /// Live Claude Code sessions on this machine — they all ride the
    /// active account's credential. Compact shows the brain only when
    /// something is actually working.
    @ViewBuilder private var agentChip: some View {
        if let live = model.liveSessions, !model.compactRows || live.busy > 0 {
            Group {
                if model.compactRows {
                    // The icon rail's cells are 20pt: side-by-side text
                    // clips there (user screenshot), so compact wears the
                    // count as a badge on the brain instead.
                    Image(systemName: "brain")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                        .overlay(alignment: .topTrailing) {
                            Text("\(live.busy)")
                                .font(.system(size: 8, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange))
                                .offset(x: 8, y: -7)
                        }
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "brain")
                            .font(.caption)
                            .foregroundStyle(live.busy > 0 ? Color.orange : Color.secondary)
                        Text(live.busy > 0 ? "\(live.busy) working · \(live.total)"
                                           : "\(live.total)")
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(live.busy > 0 ? Color.orange : Color.secondary)
                    }
                }
            }
            .help(SessionSummary.tooltip(live))
        }
    }

    /// Detach into a free-floating window (not glued to the menu bar).
    private var popOutIcon: some View {
        Button {
            model.popOut?()
        } label: {
            Image(systemName: "rectangle.on.rectangle")
        }
        .help("Pop out into a window you can move anywhere — click again to close it")
    }

    /// Claude service status — a colored dot; click opens the status page.
    private var serviceDot: some View {
        Button { status.openPage() } label: {
            Circle().fill(status.color).frame(width: 8, height: 8)
        }
        .help(status.helpText)
    }

    private var serviceChip: some View {
        Button { status.openPage() } label: {
            HStack(spacing: 4) {
                Circle().fill(status.color).frame(width: 7, height: 7)
                Text(status.shortText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .help(status.helpText)
    }

    @ViewBuilder private var engineBadge: some View {
        switch model.engineState {
        case .running: Label("auto", systemImage: "bolt.fill").foregroundStyle(.green)
        case .refused: Label("engine elsewhere", systemImage: "exclamationmark.triangle")
            .help("Another auto-switch engine (TUI or cswap auto) holds the mutex.")
        case .backingOff(let s): Label("retry \(Int(s))s", systemImage: "clock")
        case .schemaMismatch: Label("update app", systemImage: "arrow.down.circle")
        case .stopped: Label("off", systemImage: "pause")
        }
    }

    @ViewBuilder private var engineBadgeIcon: some View {
        switch model.engineState {
        case .running: Image(systemName: "bolt.fill").foregroundStyle(.green).help("auto-switch running")
        case .refused: Image(systemName: "exclamationmark.triangle")
            .help("Another auto-switch engine (TUI or cswap auto) holds the mutex.")
        case .backingOff(let s): Image(systemName: "clock").help("engine retrying in \(Int(s))s")
        case .schemaMismatch: Image(systemName: "arrow.down.circle").help("update the app")
        case .stopped: Image(systemName: "pause").help("engine off")
        }
    }
}

/// Scales the popup by rendering at 1x, measuring, then applying
/// scaleEffect with a frame sized to the scaled bounds — the only route
/// that works on macOS (Dynamic Type and @ScaledMetric are iOS-only
/// no-ops there, verified live: the size setting did nothing).
private struct PopupScale: ViewModifier {
    let scale: CGFloat
    @State private var measured: CGSize = .zero

    func body(content: Content) -> some View {
        if scale == 1 {
            content
        } else {
            content
                // fixedSize: measure the IDEAL, never the proposal. Without
                // it the outer frame (measured × scale) proposed itself
                // back into flexible content, which grew to fit, got
                // re-measured, and ran away by ×scale per pass — in the
                // pop-out window that reached 2.7e11pt and AppKit aborted.
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: { measured = $0 }
                .scaleEffect(scale, anchor: .topLeading)
                .frame(
                    width: measured == .zero ? nil : measured.width * scale,
                    height: measured == .zero ? nil : measured.height * scale,
                    alignment: .topLeading)
        }
    }
}

/// Layout chooser: wide grid rows (the classic) or stacked per-account
/// cards (narrow popup, e.g. on an ultrawide where the bar sits far away).
/// The advisory marker beside an account number, both layouts.
/// Green solid triangle: the auto-switcher's likely next target.
/// Gray hollow triangle: EVERY account is at a limit and this one
/// recovers first — visibly distinct from "no candidate shown", which
/// used to be indistinguishable from broken (user report 2026-08-30).
/// Always in the layout so numbers stay aligned.
struct NextMarker: View {
    @ObservedObject var model: AppModel
    let number: Int

    var body: some View {
        if model.nextCandidate == number {
            Image(systemName: "arrowtriangle.right.fill")
                .font(.caption2)
                .foregroundStyle(.green)
                .help("Next auto-switch target")
        } else if model.nextCandidate == nil,
                  let recovery = model.nextRecovery,
                  recovery.number == number {
            Image(systemName: "arrowtriangle.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .help("All accounts are at a limit — this one recovers "
                      + "first\(Self.eta(recovery.at))")
        } else {
            Image(systemName: "arrowtriangle.right.fill")
                .font(.caption2)
                .opacity(0)
        }
    }

    private static func eta(_ iso: String) -> String {
        guard let date = WeeklyRoll.parse(iso) else { return "" }
        return " (" + date.formatted(date: .abbreviated, time: .shortened) + ")"
    }
}

struct AccountRows: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageModel

    var body: some View {
        Group {
            if model.popupLayout == "stacked" {
                AccountStack(model: model, usage: usage)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            } else {
                AccountGrid(model: model, usage: usage)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: model.popupLayout)
        // Warm the cash figures when the popup opens in a themed mode: a
        // background `cswap usage` run, cached in the shared UsageModel.
        .onAppear { if !model.rowTheme.plain { usage.loadIfNeeded() } }
    }
}

/// Shared cell builders for both layouts — one vocabulary (RowTheme),
/// one set of rendering rules (compact hides untouched/exhausted cells,
/// themed gauges show what's LEFT, plain shows used %).
@MainActor
struct AccountCells {
    let model: AppModel
    let usage: UsageModel
    let account: Account
    /// Wide grid rows paint the active band per cell; stacked cards paint
    /// one rounded background instead.
    var banded = true

    var theme: RowTheme { model.rowTheme }
    var dead: Bool { AccountVitals.isDead(account.usage) }

    /// "Max 20x" -> "20x" in compact mode; "Enterprise" -> "Ent".
    var planText: String? {
        guard let plan = account.plan else { return nil }
        guard model.compactRows else { return plan }
        return plan.replacingOccurrences(of: "Max ", with: "")
            .replacingOccurrences(of: "Enterprise", with: "Ent")
    }

    var displayName: String {
        let name = [dead ? theme.deadMarker : nil,
                    account.icon, account.alias ?? account.email]
            .compactMap { $0 }.joined(separator: " ")
        return (account.disabled ?? false) ? "\(name)  (disabled)" : name
    }

    /// Compact mode drops cells that carry no signal: untouched (0%) and
    /// exhausted (100% — the dead marker already says it).
    func hiddenInCompact(_ pct: Double) -> Bool {
        model.compactRows && (pct <= 0 || pct >= 100)
    }

    @ViewBuilder var aheadIcon: some View {
        if theme.aheadIcon.hasPrefix("sf:") {
            let symbol = String(theme.aheadIcon.dropFirst(3))
            Image(systemName: symbol)
                .symbolRenderingMode(symbol == "flame.circle.fill" ? .palette : .monochrome)
                .foregroundStyle(.white, .orange)
        } else {
            Text(theme.aheadIcon).font(.caption)
        }
    }

    func resetText(_ w: UsageWindow) -> String? {
        guard let when = model.compactRows
            ? ResetLabel.compact(w) : ResetLabel.label(w) else { return nil }
        return (w.pct >= 100 ? theme.revivePrefix : "") + when
    }

    /// Reset label that goes LIVE under ten minutes: a per-second m:ss
    /// countdown, then a pulsing "resetting…" until the next snapshot
    /// replaces the data.
    @ViewBuilder func resetLabelView(resetsAt: String?, staticText: String?) -> some View {
        if let date = WeeklyRoll.parse(resetsAt),
           date.timeIntervalSinceNow < 600 {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = date.timeIntervalSince(ctx.date)
                if left <= 0 {
                    Text("resetting…")
                        .font(.caption).bold().foregroundStyle(.green)
                        .opacity(0.35 + 0.65 * abs(sin(
                            ctx.date.timeIntervalSinceReferenceDate * 2.5)))
                } else {
                    Text(String(format: "%d:%02d", Int(left) / 60, Int(left) % 60))
                        .font(.caption).bold().monospacedDigit()
                        .foregroundStyle(.orange)
                        .contentTransition(.numericText(countsDown: true))
                }
            }
        } else if let staticText {
            Text(staticText).font(.caption).foregroundStyle(.secondary)
        }
    }

    var deadCause: AccountVitals.DeadCause? { AccountVitals.cause(account.usage) }

    /// Every present window untouched — in compact mode all its cells are
    /// hidden, so the row needs SOMETHING or it reads as broken.
    var allFresh: Bool {
        guard let u = account.usage else { return false }
        var pcts: [Double] = []
        if let p = u.fiveHour?.pct { pcts.append(p) }
        if let p = u.sevenDay?.pct { pcts.append(p) }
        for w in u.scoped ?? [] { pcts.append(w.pct) }
        // Spend is deliberately absent: a spent credit cap left account 1
        // (0%/0%) rendering as anything but ready (user report 2026-08-30);
        // like AccountVitals, only the plan windows carry the verdict —
        // the ready cell wears the spent credit as a footnote.
        return !pcts.isEmpty && pcts.allSatisfy { $0 <= 0 }
    }

    @ViewBuilder var readyCell: some View {
        let spent = (account.usage?.spend?.pct ?? 0) >= 100
        HStack(spacing: 3) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
            Text(theme.plain ? "ready" : theme.readyLabel)
                .font(.caption).foregroundStyle(.secondary)
            if spent {
                Text("·").font(.caption).foregroundStyle(.tertiary)
                Text("\(theme.creditLabel) spent")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
        .help(spent
              ? "All plan limits untouched — usage credit spent (footnote only; the account is fully usable)"
              : "All plan limits untouched")
        .fixedSize()
        .activeBand(banded && account.active)
    }

    /// One line replacing every usage cell on a dead row. Plain words, not
    /// themed icon soup — "📦 💊 spent" read as a riddle (user-verified);
    /// only the color and the dead marker carry the theme here.
    @ViewBuilder var deadCell: some View {
        if let cause = deadCause {
            HStack(spacing: 4) {
                // Themed label + themed verb ("MP down", "🎬 sold out");
                // the plain theme keeps plain words. The tooltip carries
                // the plain-English translation either way.
                Text(theme.plain
                     ? "\(causeWord(cause)) out"
                     : "\(causeLabel(cause)) \(theme.deadVerb)")
                    .font(.caption).bold()
                    .foregroundStyle(ThemeColor.resolve(causeColor(cause)))
                Text("·").font(.caption).foregroundStyle(.tertiary)
                if let text = model.compactRows
                    ? ResetLabel.compact(resetsAt: cause.resetsAt,
                                         countdown: cause.countdown)
                    : ResetLabel.label(
                        resetsAt: cause.resetsAt, countdown: cause.countdown,
                        clock: cause.clock) {
                    Text("back").font(.caption).foregroundStyle(.secondary)
                    resetLabelView(resetsAt: cause.resetsAt, staticText: text)
                } else {
                    // No reset on record (a spent credit cap).
                    Text("spent").font(.caption).foregroundStyle(.secondary)
                }
            }
            .help("\(plainCause(cause)) is exhausted (100%) — the account "
                  + "is unusable until it resets")
            .fixedSize()
            .activeBand(banded && account.active)
        }
    }

    private func causeLabel(_ cause: AccountVitals.DeadCause) -> String {
        switch cause.kind {
        case .session: return theme.sessionLabel
        case .weekly: return theme.weeklyLabel
        case .scoped: return theme.scopedPrefix + (cause.name ?? "?")
        case .credit: return theme.creditLabel
        }
    }

    private func plainCause(_ cause: AccountVitals.DeadCause) -> String {
        switch cause.kind {
        case .session: return "The 5-hour session limit"
        case .weekly: return "The weekly limit"
        case .scoped: return "The \(cause.name ?? "model") weekly limit"
        case .credit: return "The usage-credit spend cap"
        }
    }

    private func causeWord(_ cause: AccountVitals.DeadCause) -> String {
        switch cause.kind {
        case .session: return "session"
        case .weekly: return "weekly"
        case .scoped: return cause.name ?? "model"
        case .credit: return "credit"
        }
    }

    private func causeColor(_ cause: AccountVitals.DeadCause) -> String {
        switch cause.kind {
        case .session: return theme.sessionColor
        case .weekly: return theme.weeklyColor
        case .scoped: return theme.scopedColor
        case .credit: return theme.creditColor
        }
    }

    @ViewBuilder func windowCell(_ w: UsageWindow?, session: Bool) -> some View {
        Group {
            if let w, !hiddenInCompact(w.pct) {
                HStack(spacing: 3) {
                    // Ahead-of-pace marker — ALWAYS in the layout,
                    // invisible when pace is fine, so columns never shift
                    // (a conditional icon broke alignment). Session lines
                    // carry the slot too: without it the stacked cards'
                    // 5h line started flush while 7d was indented
                    // (user screenshot 2026-08-30).
                    aheadIcon
                        .opacity(w.aheadOfPace == true ? 1 : 0)
                        .help("Burning faster than the window elapses")
                    if theme.plain {
                        Text(session ? theme.sessionLabel : theme.weeklyLabel)
                            .foregroundStyle(.secondary)
                        Text("\(Int(w.pct))%")
                            .foregroundStyle(w.pct >= 100 ? .red : .primary)
                            .monospacedDigit()
                            .contentTransition(.numericText(value: w.pct))
                    } else {
                        Text(session ? theme.sessionLabel : theme.weeklyLabel)
                            .font(.caption).bold()
                            .foregroundStyle(ThemeColor.resolve(
                                session ? theme.sessionColor : theme.weeklyColor))
                            .help(session ? "Session window left" : "Weekly window left")
                        GaugeBar(
                            remaining: GaugeMath.remaining(usedPct: w.pct),
                            color: ThemeColor.resolve(
                                session ? theme.sessionColor : theme.weeklyColor))
                    }
                    resetLabelView(resetsAt: w.resetsAt, staticText: resetText(w))
                }
                // fixedSize: usage is the row's payload — grow the popup
                // rather than truncate; the name column stays flexible.
                .fixedSize()
                .glowOnChange(of: w.pct, color: ThemeColor.flash(theme))
            } else if w == nil, banded, !model.compactRows {
                Text("—").foregroundStyle(.tertiary)
            } else if banded, !model.compactRows {
                // Placeholder stretches to its COLUMN width: a zero-width
                // cell left a hole in the active row's highlight band.
                // gridCellUnsizedAxes: fill the column WITHOUT driving its
                // size — a bare infinity frame inflated the grid's measured
                // width past the popover (user: overflow both edges).
                Text(verbatim: "")
                    .frame(maxWidth: .infinity)
                    .gridCellUnsizedAxes(.horizontal)
            }
        }
        .activeBand(banded && account.active)
    }

    @ViewBuilder var spendCell: some View {
        if let spend = account.usage?.spend, spend.pct >= 100 {
            // Spent credit is a footnote, not a death: the overflow buffer
            // is gone, the subscription windows still rule the row. The
            // invisible pace slot keeps it aligned with the gauge lines
            // in the stacked cards.
            HStack(spacing: 3) {
                aheadIcon.opacity(0)
                Text("\(theme.creditLabel) spent")
            }
                .font(.caption).foregroundStyle(.tertiary)
                .help(String(format: "usage credit exhausted: %.2f of %.0f %@ — "
                             + "account still usable on its plan limits",
                             spend.used, spend.limit, spend.currency))
                .fixedSize()
                .activeBand(banded && account.active)
        } else if let spend = account.usage?.spend, !hiddenInCompact(spend.pct) {
            HStack(spacing: 3) {
                aheadIcon.opacity(0)
                Text(theme.creditLabel)
                    .font(theme.plain ? .body : .caption.bold())
                    .foregroundStyle(theme.plain
                                     ? Color.secondary
                                     : ThemeColor.resolve(theme.creditColor))
                if theme.plain {
                    Text("\(Int(spend.pct))%")
                        .foregroundStyle(spend.pct >= 100 ? .red : .primary)
                        .monospacedDigit()
                        .contentTransition(.numericText(value: spend.pct))
                } else {
                    GaugeBar(remaining: GaugeMath.remaining(usedPct: spend.pct),
                             color: ThemeColor.resolve(theme.creditColor))
                }
            }
            .help(String(format: "usage credit: %.2f of %.0f %@",
                         spend.used, spend.limit, spend.currency))
            .fixedSize()
            .glowOnChange(of: spend.pct, color: ThemeColor.flash(theme))
            .activeBand(banded && account.active)
        } else if banded, !model.compactRows {
            // Text, not Color.clear: a zero-size cell renders the active
            // band as a stray blob; an empty Text has line height. Stretch
            // so the band fills the column other rows widened. Grid only —
            // in the stacked VStack this rendered as a stray blank line
            // (user screenshot 2026-08-30).
            Text(verbatim: "")
                .frame(maxWidth: .infinity)
                .gridCellUnsizedAxes(.horizontal)
                .activeBand(banded && account.active)
        }
    }

    @ViewBuilder var scopedCells: some View {
        ForEach(account.usage?.scoped ?? [], id: \.name) { w in
            Group {
                if hiddenInCompact(w.pct) {
                    if banded, !model.compactRows {
                        Text(verbatim: "")
                            .frame(maxWidth: .infinity)
                            .gridCellUnsizedAxes(.horizontal)
                    }
                } else {
                    HStack(spacing: 3) {
                        aheadIcon
                            .opacity(w.aheadOfPace == true ? 1 : 0)
                            .help("Burning faster than the window elapses")
                        if theme.plain {
                            Text(w.name ?? "?").foregroundStyle(.secondary)
                            Text("\(Int(w.pct))%")
                                .foregroundStyle(w.pct >= 100 ? .red : .primary)
                                .monospacedDigit()
                                .contentTransition(.numericText(value: w.pct))
                        } else {
                            Text(theme.scopedPrefix + (w.name ?? "?"))
                                .font(.caption).bold()
                                .foregroundStyle(ThemeColor.resolve(theme.scopedColor))
                                .help("Model weekly limit left")
                            GaugeBar(remaining: GaugeMath.remaining(usedPct: w.pct),
                                     color: ThemeColor.resolve(theme.scopedColor))
                        }
                    }
                }
            }
            .fixedSize()
            .glowOnChange(of: w.pct, color: ThemeColor.flash(theme))
            .activeBand(banded && account.active)
        }
    }

    /// Estimated 7-day API-price spend from the Usage tab's cached
    /// report — never triggers the multi-second scan itself.
    @ViewBuilder var cashCell: some View {
        if !theme.plain,
           let row = usage.report?.accounts.first(where: { $0.number == account.number }) {
            let usd = Int(row.estimatedUSD)
            Text(verbatim: model.compactRows && usd >= 1000
                 ? "\(theme.cashIcon)\(Int((Double(usd) / 1000).rounded()))k"
                 : "\(theme.cashIcon)\(usd.formatted())")
                .font(.caption).foregroundStyle(.yellow)
                .help("Estimated API-price spend, last \(usage.report?.days ?? 7) days — not a bill")
                .fixedSize()
                .activeBand(banded && account.active)
        }
    }
}

/// Maps a theme color string — named or "#rrggbb" — to a SwiftUI Color.
enum ThemeColor {
    /// Animation accent for a theme — the app accent when unset.
    static func flash(_ theme: RowTheme) -> Color {
        theme.flashColor.isEmpty ? .accentColor : resolve(theme.flashColor)
    }

    static func resolve(_ name: String) -> Color {
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
        case "gray", "secondary": return .secondary
        default:
            guard name.hasPrefix("#"), name.count == 7,
                  let v = UInt32(name.dropFirst(), radix: 16) else { return .primary }
            return Color(red: Double((v >> 16) & 0xff) / 255,
                         green: Double((v >> 8) & 0xff) / 255,
                         blue: Double(v & 0xff) / 255)
        }
    }
}

/// The account rows as a real Grid — the alignment the rumps menubar had to
/// fake with monospaced padding (spec §4). The active row gets a contiguous
/// highlight band: Grid offers no per-row background, so each cell paints one
/// and extends it exactly half the row's spacing in every direction — the
/// segments meet edge-to-edge (an overlap would double the translucent
/// color's alpha and show as darker stripes).
struct AccountGrid: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageModel

    /// Usage-column count of the WIDEST row: 5h + 7d + spend + each
    /// scoped window. Rows that span (dead/ready/sentinel) must cover
    /// exactly this many columns or the cash column shifts left.
    private var usageColumns: Int {
        3 + (model.accounts.map { ($0.usage?.scoped ?? []).count }.max() ?? 0)
    }

    private static func union(_ rects: [CGRect]) -> CGRect? {
        rects.dropFirst().reduce(rects.first) { $0?.union($1) }
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            ForEach(model.accounts, id: \.number) { account in
                let cells = AccountCells(model: model, usage: usage, account: account)
                GridRow {
                    HStack(spacing: 2) {
                        NextMarker(model: model, number: account.number)
                        Text("\(account.number)")
                            .fontWeight(account.active ? .bold : .regular)
                            .foregroundStyle(account.active ? Color.accentColor : Color.primary)
                    }
                    .activeBand(account.active)
                    Button(cells.displayName) {
                        // disabled rows stay clickable, like rumps; the
                        // popup-level alert asks before committing
                        if !account.active { model.pendingSwitch = account.number }
                    }
                    .buttonStyle(.plain)
                    .fontWeight(account.active ? .bold : .regular)
                    .foregroundStyle((account.disabled ?? false) || cells.dead
                                     ? AnyShapeStyle(.secondary)
                                     : account.active
                                     ? AnyShapeStyle(Color.accentColor)
                                     : AnyShapeStyle(.primary))
                    .help(cells.dead ? "Out of at least one limit — unusable until it resets"
                                     : "Switch to this account")
                    .lineLimit(1)
                    // The one deliberately flexible column: emails truncate,
                    // usage numbers and reset times never do.
                    .frame(minWidth: 110, maxWidth: 230, alignment: .leading)
                    .activeBand(account.active)
                    Text(cells.planText ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .activeBand(account.active)
                    if let note = SentinelNotes.note(for: account.usageStatus) {
                        Text(note)
                            .foregroundStyle(.secondary)
                            .gridCellColumns(usageColumns)
                            .activeBand(account.active)
                    } else if cells.dead {
                        // A dead row shows ONLY what blocks it — a full MP
                        // gauge on an unusable account reads as usable.
                        cells.deadCell
                            .gridCellColumns(usageColumns)
                        cells.cashCell
                    } else if cells.allFresh {
                        // A fully-available account carries no signal worth
                        // five gauges — one "ready" line in every mode.
                        cells.readyCell
                            .gridCellColumns(usageColumns)
                        cells.cashCell
                    } else if model.compactRows {
                        // Compact hides empty/exhausted cells, which makes
                        // per-cell grid columns meaningless — a row whose 5h
                        // cell vanished would show its 7d gauge floating in
                        // the wrong column. Pack the visible cells tight in
                        // ONE cell; only number/name/plan/cash stay columns.
                        HStack(spacing: 12) {
                            cells.windowCell(account.usage?.fiveHour, session: true)
                            cells.windowCell(account.usage?.sevenDay, session: false)
                            cells.spendCell
                            cells.scopedCells
                        }
                        .fixedSize()
                        .activeBand(account.active)
                        .gridCellColumns(usageColumns)
                        cells.cashCell
                    } else {
                        cells.windowCell(account.usage?.fiveHour, session: true)
                        cells.windowCell(account.usage?.sevenDay, session: false)
                        cells.spendCell
                        cells.scopedCells
                        cells.cashCell
                    }
                }
            }
        }
        // One band + one sweep for the whole active row (Grid has no
        // per-row view): union the reported cell bounds, draw full-width.
        // ± half the 8pt verticalSpacing so rows still read separated.
        .backgroundPreferenceValue(ActiveCellBounds.self) { anchors in
            GeometryReader { geo in
                if let row = Self.union(anchors.map { geo[$0] }) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.30))
                        .frame(width: geo.size.width, height: row.height + 8)
                        .offset(y: row.minY - 4)
                }
            }
        }
        .overlayPreferenceValue(ActiveCellBounds.self) { anchors in
            GeometryReader { geo in
                if let row = Self.union(anchors.map { geo[$0] }) {
                    Color.clear
                        .frame(width: geo.size.width, height: row.height + 8)
                        .switchFlash(model.switchFlashTick,
                                     color: ThemeColor.flash(model.rowTheme))
                        .offset(y: row.minY - 4)
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

/// Stacked layout: one card per account — narrow and tall instead of wide.
struct AccountStack: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.accounts, id: \.number) { account in
                let cells = AccountCells(model: model, usage: usage, account: account, banded: false)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        NextMarker(model: model, number: account.number)
                        Text("\(account.number)")
                            .fontWeight(.bold)
                            .foregroundStyle(account.active ? Color.accentColor : Color.secondary)
                        Button(cells.displayName) {
                            if !account.active { model.pendingSwitch = account.number }
                        }
                            .buttonStyle(.plain)
                            .fontWeight(account.active ? .bold : .regular)
                            .foregroundStyle((account.disabled ?? false) || cells.dead
                                             ? .secondary : .primary)
                            .lineLimit(1)
                        if let plan = cells.planText {
                            Text(plan).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        cells.cashCell
                    }
                    if let note = SentinelNotes.note(for: account.usageStatus) {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    } else if cells.dead {
                        cells.deadCell
                    } else if cells.allFresh {
                        cells.readyCell
                    } else {
                        // One attribute per line — the whole point of the
                        // stacked layout (user request 2026-08-30).
                        cells.windowCell(account.usage?.fiveHour, session: true)
                        cells.windowCell(account.usage?.sevenDay, session: false)
                        cells.spendCell
                        cells.scopedCells
                    }
                }
                .padding(8)
                // Equal-width cards, not ragged islands: every card wears
                // chrome (user: "stack cards layout need big improvement",
                // 2026-08-30); the active one keeps the accent.
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if account.active {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.26))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.accentColor.opacity(0.7)))
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.07))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(Color.primary.opacity(0.12)))
                    }
                }
                .switchFlash(account.active ? model.switchFlashTick : 0,
                             color: ThemeColor.flash(model.rowTheme))
            }
        }
    }
}

/// Cells of the active row report their bounds; AccountGrid draws ONE
/// full-width band over their union. Per-cell backgrounds sized to each
/// cell's own height read as mismatched patches with seams — gauge cells
/// are taller than text cells (user screenshot 2026-08-30).
struct ActiveCellBounds: PreferenceKey {
    static let defaultValue: [Anchor<CGRect>] = []
    static func reduce(value: inout [Anchor<CGRect>],
                       nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

private struct ActiveBand: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content.anchorPreference(key: ActiveCellBounds.self, value: .bounds) {
            active ? [$0] : []
        }
    }
}

private extension View {
    func activeBand(_ on: Bool) -> some View { modifier(ActiveBand(active: on)) }
}

/// Type-erased LabelStyle so one Label can flip icon-only <-> titled at
/// runtime (the ternary needs a single concrete type).
struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init(_ style: some LabelStyle) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }
    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}
