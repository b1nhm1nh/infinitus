import SwiftUI
import CswapCore

/// Standalone "Animation Playground" window (user 2026-08-31: "you need
/// a window playground to test everything else"; "same UI as production,
/// with ... one [account] with each state"). The REAL popup body
/// (MenuContent) on the live model up top — in mock mode the demo
/// fleet covers every account condition — then the self-contained demos — burn styles
/// side by side under one heat dial, the HP drop, window-reset refills,
/// the inline samples — in a resizable window, freed from the
/// fixed-height Settings pane. The popup embed carries its own control
/// rail (user 2026-08-31): replay intro, dead/revived/switch through
/// the real diff path, and sandboxed layout/size/animation knobs.
@MainActor enum Playground {
    static var window: NSWindow?
    /// The playground's PRIVATE model: pinned to the demo script with
    /// every outward side effect suppressed (AppModel.isPlayground) —
    /// switching, rotating, reordering in here touches demo state only,
    /// never real accounts (user 2026-08-31).
    static var demoModel: AppModel?
    /// The demo script's dead hook: while this file exists, alpha's 5h
    /// window reads 100% — the row dies through the real refresh-diff
    /// path (death beat), and removal revives it (spring refill).
    static var deadFlag: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("infinitus-demo-dead")
    }

    /// Dev-loop hook: INFINITUS_PLAYGROUND=1 in the environment opens
    /// the window at launch. An env var on purpose — a defaults bool
    /// would stick and greet every future launch with a playground.
    static func openAtLaunchIfAsked(usage: UsageModel) {
        guard ProcessInfo.processInfo.environment["INFINITUS_PLAYGROUND"] == "1"
        else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            show(usage: usage)
        }
    }

    static func show(usage: UsageModel) {
        if window == nil {
            // Fresh start: the fleet opens alive even if a previous run
            // left the dead hook behind.
            try? FileManager.default.removeItem(at: deadFlag)
            let demo = AppModel(playground: true)
            demo.startFeeds()
            demoModel = demo
            let host = NSHostingController(
                rootView: PlaygroundView(model: demo, usage: usage))
            // Never let SwiftUI size the window (the pop-out's unbounded
            // ideal-width crash class); sized once below, user-owned after.
            host.sizingOptions = []
            let w = NSWindow(contentViewController: host)
            w.title = "Animation Playground"
            w.styleMask = [.titled, .closable, .resizable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 720, height: 660))
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct PlaygroundView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var usage: UsageModel
    @State private var ahead: Double = 30      // points ahead of pace
    @State private var zoom: Double = 2
    @State private var dropHP: Double = 100
    @State private var refill: Double = 100
    @State private var flash = 0
    @State private var pulse = 0
    /// Mirrors the demo dead hook (cleared on window creation, so the
    /// fleet starts alive and this starts truthful).
    @State private var demoDead = false

    private var burnHeat: Double {
        GaugeMath.burnHeat(usedPct: 64, expectedPct: 64 - ahead,
                           ahead: ahead > 0)
    }
    private let sevenths = (1..<7).map { Double($0) * 100 / 7 }

    /// popupLayout behind withAnimation, matching DisplayPane's tiles —
    /// the embedded popup re-flows live instead of snapping.
    private var layoutBinding: Binding<String> {
        Binding(get: { model.popupLayout },
                set: { v in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        model.popupLayout = v
                    }
                })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("Production popup — the real UI on the demo fleet") {
                    Text("Always the mock cast (healthy, ahead mild + hot, "
                         + "dead, fresh, behind pace, sentinel, disabled, "
                         + "near-reset) on a private engine — the buttons "
                         + "and knobs here are sandboxed too: nothing below "
                         + "touches your real accounts or settings.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button("Replay intro") { model.replayIntro() }
                        Button("Play account switch") {
                            // A real engine switch on the demo fleet — the
                            // sweep fires from the active-number diff,
                            // same as production.
                            let candidates = model.accounts.filter {
                                !$0.active && $0.usage != nil
                                    && $0.disabled != true
                            }
                            if let next = candidates.randomElement() {
                                model.switchTo(next.number)
                            }
                        }
                        // Dead/revived run the REAL pipeline: the demo
                        // script's dead hook pins alpha's 5h at 100%, so
                        // the refresh diff plays the death beat; removing
                        // it jumps the bar +63 — the spring refill.
                        Button("Play dead") {
                            try? Data().write(to: Playground.deadFlag)
                            demoDead = true
                            Task { await model.refreshSnapshot() }
                        }
                        .disabled(demoDead)
                        Button("Play revived") {
                            try? FileManager.default
                                .removeItem(at: Playground.deadFlag)
                            demoDead = false
                            Task { await model.refreshSnapshot() }
                        }
                        .disabled(!demoDead)
                    }
                    HStack(spacing: 14) {
                        Picker("Layout", selection: layoutBinding) {
                            Text("Wide rows").tag("wide")
                            Text("Stacked cards").tag("stacked")
                            Text("Horizontal cards").tag("hstack")
                        }
                        .fixedSize()
                        Picker("Size", selection: $model.popupTextSize) {
                            Text("Default").tag("default")
                            Text("Large").tag("large")
                            Text("X-Large").tag("xlarge")
                            Text("Huge").tag("huge")
                        }
                        .fixedSize()
                        Toggle("Compact rows", isOn: $model.compactRows)
                    }
                    HStack(spacing: 14) {
                        Picker("Theme", selection: $model.gamification) {
                            ForEach(model.availableThemes) { t in
                                Text(t.name).tag(t.id)
                            }
                        }
                        .fixedSize()
                        Picker("Pace fire", selection: $model.burnStyle) {
                            Text("Off").tag("off")
                            Text("Ember glow").tag("ember")
                            Text("Flame licks").tag("flame")
                            Text("Limit break").tag("limit")
                        }
                        .fixedSize()
                        Picker("Intro", selection: $model.introStyle) {
                            Text("Slide from top").tag("top")
                            Text("Slide from bottom").tag("bottom")
                            Text("Fade in").tag("fade")
                            Text("Rows from right").tag("rows")
                            // A legal live value (the reveal's default
                            // arm) — without it the picker renders blank
                            // for prefs that hold "off".
                            Text("Off").tag("off")
                        }
                        .fixedSize()
                        Picker("Title", selection: $model.introTitle) {
                            Text("Zoom bounce").tag("zoom")
                            Text("Stamp slam").tag("slam")
                            Text("Spin up").tag("spin")
                            Text("Off").tag("off")
                        }
                        .fixedSize()
                    }
                    HStack(spacing: 14) {
                        Text("Intro speed").font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $model.introSpeed, in: 0.4...2)
                            .frame(width: 140)
                        Text(String(format: "%.1fx", model.introSpeed))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    MenuContent(model: model, usage: usage)
                        .fixedSize()
                        .background(RoundedRectangle(cornerRadius: 10)
                            .fill(.black.opacity(0.15)))
                }
                Divider()
                section("Pace fire — every style, one heat dial") {
                    HStack(spacing: 14) {
                        Slider(value: $ahead, in: 0...40).frame(width: 160)
                        Text("+\(Int(ahead)) pts ahead")
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 84, alignment: .leading)
                        Slider(value: $zoom, in: 1...4).frame(width: 120)
                        Text(String(format: "%.1f\u{00d7}", zoom))
                            .font(.caption).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    ForEach([("ember", "Ember glow"), ("flame", "Flame licks"),
                             ("limit", "Limit break")], id: \.0) { style, label in
                        HStack(spacing: 12) {
                            Text(label).font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)
                            GaugeBar(remaining: 36, color: .orange,
                                     paceRemaining: 36 + ahead,
                                     dividers: sevenths,
                                     burnStyle: style, burnHeat: burnHeat)
                                .scaleEffect(zoom, anchor: .leading)
                                .frame(width: 110 * zoom, height: 32 * zoom,
                                       alignment: .leading)
                        }
                    }
                }
                section("HP drop (one-refresh plunge of 10\u{2013}60 points)") {
                    // Plain VStack with headroom, NOT a Form cell — the
                    // 5\u{00d7} zoom needs room (a clipped demo would read
                    // as a broken effect).
                    HStack(spacing: 12) {
                        GaugeBar(remaining: dropHP, color: .blue,
                                 paceRemaining: 55,
                                 dividers: (1..<5).map { Double($0) * 20 })
                        ForEach([15.0, 35, 55], id: \.self) { n in
                            Button("\u{2212}\(Int(n))") { dropHP -= n }
                                .disabled(dropHP < n)
                        }
                        Button("Refill") { dropHP = 100 }
                            .disabled(dropHP > 74)
                    }
                    .padding(.vertical, 40)
                }
                section("Window reset (refill)") {
                    HStack(spacing: 12) {
                        GaugeBar(remaining: refill, color: .blue,
                                 paceRemaining: 55,
                                 dividers: (1..<5).map { Double($0) * 20 })
                        Button("Replay 5h reset") {
                            refill = 8
                            DispatchQueue.main.asyncAfter(
                                deadline: .now() + 0.1) { refill = 100 }
                        }
                        Button("Replay 7d reset") {
                            refill = 22
                            DispatchQueue.main.asyncAfter(
                                deadline: .now() + 0.1) { refill = 100 }
                        }
                    }
                }
                section("Inline samples") {
                    HStack(spacing: 12) {
                        Text("4  sample@account.com").bold()
                        Spacer()
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.30)))
                    .switchFlash(flash)
                    HStack(spacing: 10) {
                        Button("Replay switch sweep") { flash += 1 }
                        Text("LIFE 84%").font(.caption).bold()
                            .foregroundStyle(.green)
                            .glowOnChange(of: pulse)
                        Button("Replay data-change glow") { pulse += 1 }
                        Text(model.rowTheme.plain
                             || model.rowTheme.resetWord.isEmpty
                             ? "resetting\u{2026}" : model.rowTheme.resetWord)
                            .font(.caption).bold().foregroundStyle(.green)
                            .pulseOpacity()
                    }
                }
                Text("The knobs up top are the playground's own copy \u{2014} "
                     + "the real ones live in Settings \u{2192} Display / "
                     + "Animations and write your actual prefs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func section(_ title: String,
                         @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }
}
