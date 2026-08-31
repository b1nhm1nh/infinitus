import SwiftUI
import CswapCore

/// Standalone "Animation Playground" window (user 2026-08-31: "you need
/// a window playground to test everything else"; "same UI as production,
/// with ... one [account] with each state"). The REAL popup body
/// (MenuContent) on the live model up top — in mock mode the demo
/// fleet covers every account condition — then the self-contained demos — burn styles
/// side by side under one heat dial, the HP drop, window-reset refills,
/// the inline samples — in a resizable window, freed from the
/// fixed-height Settings pane. Popup-bound triggers (intro replay,
/// live-row flash, death beat) stay in the Animations debug pane
/// because they need the popup open.
@MainActor enum Playground {
    static var window: NSWindow?

    /// Dev-loop hook: INFINITUS_PLAYGROUND=1 in the environment opens
    /// the window at launch. An env var on purpose — a defaults bool
    /// would stick and greet every future launch with a playground.
    static func openAtLaunchIfAsked(model: AppModel, usage: UsageModel) {
        guard ProcessInfo.processInfo.environment["INFINITUS_PLAYGROUND"] == "1"
        else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            show(model: model, usage: usage)
        }
    }

    static func show(model: AppModel, usage: UsageModel) {
        if window == nil {
            let host = NSHostingController(
                rootView: PlaygroundView(model: model, usage: usage))
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

    private var burnHeat: Double {
        GaugeMath.burnHeat(usedPct: 64, expectedPct: 64 - ahead,
                           ahead: ahead > 0)
    }
    private let sevenths = (1..<7).map { Double($0) * 100 / 7 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("Production popup — the real UI on the live model") {
                    Text("Mock mode feeds it the full-state cast: healthy, "
                         + "ahead of pace (mild + hot), dead, fresh, behind "
                         + "pace, re-login sentinel, disabled, near-reset.")
                        .font(.caption).foregroundStyle(.secondary)
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
                Text("Popup-bound animations (intro choreography, live-row "
                     + "flash, death beat) audition from Settings \u{2192} "
                     + "Animations with the popup open.")
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
