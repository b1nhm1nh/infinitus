import SwiftUI
import CswapCore

/// Debug-only Settings tab (defaults write <bundle-id> debug_menu -bool
/// true): fire every popup animation on demand, without waiting for a
/// real switch, snapshot delta, or a window's final ten minutes.
struct AnimationsDebugPane: View {
    @ObservedObject var model: AppModel
    @State private var sampleFlash = 0
    @State private var samplePulse = 0
    @State private var resetDemo = Date().addingTimeInterval(605)

    var body: some View {
        Form {
            Section("Live popup (fires on the real rows)") {
                Button("Flash the active row (switch celebration)") {
                    model.switchFlashTick += 1
                }
                Button("Ripple the data-changed dot") {
                    model.dataPulseTick += 1
                }
                Text("Open the popup first — these trigger the real "
                     + "animations in it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Inline samples") {
                HStack(spacing: 12) {
                    Text("4  sample@account.com").bold()
                    Spacer()
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.30)))
                .switchFlash(sampleFlash)
                Button("Replay switch sweep") { sampleFlash += 1 }
                HStack(spacing: 10) {
                    DataPulseDot(trigger: samplePulse)
                    Button("Replay data ripple") { samplePulse += 1 }
                }
                HStack(spacing: 10) {
                    Text("Countdown / resetting pulse:")
                        .font(.caption).foregroundStyle(.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        let left = resetDemo.timeIntervalSince(ctx.date)
                        if left <= 0 {
                            Text("resetting…")
                                .font(.caption).bold().foregroundStyle(.green)
                                .opacity(0.35 + 0.65 * abs(sin(
                                    ctx.date.timeIntervalSinceReferenceDate * 2.5)))
                        } else {
                            Text(String(format: "%d:%02d",
                                        Int(left) / 60, Int(left) % 60))
                                .font(.caption).bold().monospacedDigit()
                                .foregroundStyle(.orange)
                                .contentTransition(.numericText(countsDown: true))
                        }
                    }
                    Button("Restart at 0:05") {
                        resetDemo = Date().addingTimeInterval(5)
                    }
                    Button("Restart at 10:05") {
                        resetDemo = Date().addingTimeInterval(605)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
