import ActivityKit
import SwiftUI
import WidgetKit

@main
struct InfinitusWidgets: WidgetBundle {
    var body: some Widget {
        RevivalLiveActivity()
        WorkingLiveActivity()
    }
}

// MARK: - #1 all-dead revival countdown

struct RevivalLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RevivalActivity.self) { context in
            RevivalLockScreen(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.6))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 4) {
                        if context.state.revived {
                            Text("\(context.state.reviver) is back").font(.headline)
                        } else {
                            Text("All accounts limited")
                                .font(.caption).foregroundStyle(.orange)
                            Text(timerInterval: Date.now...context.state.revivesAt, countsDown: true)
                                .font(.system(.title, design: .rounded).weight(.semibold))
                                .monospacedDigit().multilineTextAlignment(.center)
                            Text("\(context.state.reviver) recovers · \(context.state.sessions) sessions")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.revived ? "bolt.fill" : "hourglass")
                    .foregroundStyle(.orange)
            } compactTrailing: {
                if context.state.revived {
                    Text("back").font(.caption2)
                } else {
                    Text(timerInterval: Date.now...context.state.revivesAt, countsDown: true)
                        .monospacedDigit().font(.caption2).frame(maxWidth: 52)
                }
            } minimal: {
                Image(systemName: "hourglass").foregroundStyle(.orange)
            }
        }
    }
}

private struct RevivalLockScreen: View {
    let state: RevivalActivity.ContentState
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.revived ? "bolt.fill" : "hourglass")
                .font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                if state.revived {
                    Text("Revived — \(state.reviver) is back").font(.headline)
                } else {
                    Text("All accounts limited").font(.caption).foregroundStyle(.orange)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(state.reviver).font(.headline)
                        Text("recovers in").font(.caption).foregroundStyle(.secondary)
                        Text(timerInterval: Date.now...state.revivesAt, countsDown: true)
                            .font(.headline).monospacedDigit()
                    }
                    Text("\(state.sessions) session\(state.sessions == 1 ? "" : "s") waiting to resume")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

// MARK: - #2 working sessions

struct WorkingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkingActivity.self) { context in
            WorkingLockScreen(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.6))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.active).font(.headline)
                        if let plan = context.state.plan {
                            Text(plan).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.busy) working · \(context.state.total)")
                        .font(.caption).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 4) {
                        Gauge(value: context.state.bindingPct, in: 0...100) { EmptyView() }
                            .gaugeStyle(.accessoryLinearCapacity)
                            .tint(gaugeTint(context.state.bindingPct))
                        HStack {
                            Text("\(context.state.bindingLabel) \(Int(context.state.bindingPct))%")
                                .font(.caption2).monospacedDigit()
                            Spacer()
                            if let next = context.state.next {
                                Text("next: \(next)").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } compactLeading: {
                Text("∞").font(.headline)
            } compactTrailing: {
                Text("\(Int(context.state.bindingPct))%")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(gaugeTint(context.state.bindingPct))
            } minimal: {
                Text("\(Int(context.state.bindingPct))")
                    .font(.caption2).monospacedDigit()
            }
        }
    }
}

private struct WorkingLockScreen: View {
    let state: WorkingActivity.ContentState
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(state.active).font(.headline)
                Gauge(value: state.bindingPct, in: 0...100) { EmptyView() }
                    .gaugeStyle(.accessoryLinearCapacity)
                    .tint(gaugeTint(state.bindingPct))
                    .frame(width: 110)
                Text("\(state.bindingLabel) \(Int(state.bindingPct))%")
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(state.busy) working").font(.headline).monospacedDigit()
                Text("\(state.total) session\(state.total == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
                if let next = state.next {
                    Text("→ \(next)").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
    }
}

private func gaugeTint(_ pct: Double) -> Color {
    pct >= 90 ? .red : pct >= 70 ? .orange : .green
}
