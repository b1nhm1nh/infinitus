import SwiftUI
import InfinitusCore

/// The reset battle plan (#7 MVP step 3, manual mode): one caption line
/// naming the steps the planner proposes, and — when a step is an
/// ignition — a confirm-gated button that runs it. Two taps: the first
/// arms ("Sure?"), the second fires; the arm times out on its own so a
/// stray click never ignites. Nothing runs by itself.
public struct BattlePlanLine<M: FleetModel>: View {
    @ObservedObject var model: M
    @State private var armed = false

    public init(model: M) {
        self.model = model
    }

    @ViewBuilder public var body: some View {
        if let plan = model.battlePlan {
            HStack(spacing: 6) {
                (Text(Image(systemName: "flag.checkered"))
                    .foregroundStyle(.orange)
                 + Text(" " + summary(plan)))
                    .font(PopupFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let n = plan.igniteNumber {
                    igniteButton(n)
                }
            }
            .fixedSize()
            .help(plan.steps.map(\.why).joined(separator: "\n"))
        }
    }

    @ViewBuilder private func igniteButton(_ n: Int) -> some View {
        if model.igniting == n {
            ProgressView().controlSize(.mini)
        } else {
            Button {
                if armed {
                    armed = false
                    model.ignite(n)
                } else {
                    armed = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(6))
                        armed = false
                    }
                }
            } label: {
                Text(armed ? "Sure? Ignite \(name(n))" : "Ignite \(name(n))")
                    .font(PopupFont.caption)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background((armed ? Color.orange : Color.secondary).opacity(0.2),
                                in: Capsule())
                    .foregroundStyle(armed ? .orange : .secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private func summary(_ plan: WindowPlanner.Plan) -> String {
        plan.steps.map { step in
            let when = step.at <= Date().timeIntervalSince1970 + 30
                ? "now" : clock(step.at)
            switch step.action {
            case .ignite(let n): return "ignite \(name(n)) \(when)"
            case .switchTo(let n): return "switch to \(name(n)) \(when)"
            case .hold(let n): return "hold \(name(n)) \(when)"
            case .reset(let n): return "\(name(n)) resets \(when)"
            }
        }.joined(separator: " → ")
    }

    private func name(_ n: Int) -> String {
        model.accounts.first { $0.number == n }
            .map { $0.alias ?? String($0.email.prefix(while: { $0 != "@" })) } ?? "#\(n)"
    }

    private func clock(_ t: Double) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}
