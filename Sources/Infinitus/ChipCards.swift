import SwiftUI
import CswapCore

/// One-line usage summary for a gauge's instant tooltip — the CodexBar
/// vocabulary ("24% in reserve · lasts until reset" / "6% in deficit ·
/// runs out in ~2d"), built from the engine's weekly pace fields.
enum WindowSummary {
    static func line(_ w: UsageWindow, kind: String) -> String {
        let left = max(0, 100 - w.pct)
        var parts = ["\(kind) \(Int(left))% left"]
        if let expected = w.expectedPct {
            let delta = Int((expected - w.pct).rounded())
            if delta >= 1 {
                parts.append("\(delta)% in reserve")
            } else if delta <= -1 {
                parts.append("\(-delta)% in deficit")
            } else {
                parts.append("on pace")
            }
        }
        if w.willLastToReset == true {
            parts.append("lasts until reset")
        } else if let out = WeeklyRoll.parse(w.projectedExhaustionAt) {
            parts.append("runs out \(out.formatted(.relative(presentation: .numeric)))")
        }
        if let reset = w.countdown ?? w.clock {
            parts.append("resets \(reset)")
        }
        // CodexBar's quota math: how many 5h session windows fit in the
        // time left on a weekly bar.
        if kind.hasPrefix("Weekly"), let reset = WeeklyRoll.parse(w.resetsAt) {
            let hoursLeft = max(0, reset.timeIntervalSinceNow / 3600)
            parts.append(String(format: "%.0f session windows until reset",
                                (hoursLeft / 5).rounded()))
        }
        return parts.joined(separator: " · ")
    }
}

/// Instant hover card for the service-status chip: per-product rows,
/// statuspage-style (user screenshot 2026-08-30). Click still opens the
/// status page.
struct StatusHoverCard: ViewModifier {
    @ObservedObject var status: ServiceStatusModel
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .overlay(alignment: .bottomLeading) {
                if hovering, !status.components.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(status.components, id: \.0) { name, state in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(state == "operational" ? Color.green : Color.orange)
                                    .frame(width: 7, height: 7)
                                Text(name).font(.caption)
                                Spacer(minLength: 12)
                                Text(state.replacingOccurrences(of: "_", with: " "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        Text("Click to open the status page")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(10)
                    .frame(width: 240)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.regularMaterial)
                            .shadow(radius: 4, y: 2))
                    .offset(y: -18)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .zIndex(hovering ? 2 : 0)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// The brain chip's click-through: every live Claude Code session with
/// status, directory, and age ("can active session be clickable and show
/// something?" — this is the something).
struct SessionListCard: View {
    let live: LiveSessions
    @ObservedObject var progress: SessionProgressModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SessionSummary.tooltip(live))
                .font(.caption).foregroundStyle(.secondary)
            if let sessions = live.sessions, !sessions.isEmpty {
                Divider()
                ForEach(sessions, id: \.pid) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(color(for: s.status))
                                .frame(width: 7, height: 7)
                            Text(shortCwd(s.cwd))
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 12)
                            Text(s.status)
                                .font(.caption).foregroundStyle(.secondary)
                            Text(age(s.startedAt))
                                .font(.caption2).foregroundStyle(.tertiary)
                                .monospacedDigit()
                        }
                        if let p = progress.byPid[s.pid], p.hasProgressSignal {
                            SessionProgressLine(progress: p)
                        }
                    }
                    .help("pid \(s.pid) · \(s.kind) · \(s.cwd)")
                }
            } else {
                Text("Session detail needs a newer cswap engine.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 340)
        .task(id: live.sessions?.map(\.pid)) {
            while !Task.isCancelled {
                progress.refresh(sessions: live.sessions ?? [])
                try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
            }
        }
    }

    private func color(for status: String) -> Color {
        switch status {
        case "busy": return .orange
        case "waiting": return .yellow
        case "idle": return .green
        case "shell": return .blue
        default: return .gray
        }
    }

    private func shortCwd(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    private func age(_ epochMs: Double) -> String {
        let started = Date(timeIntervalSince1970: epochMs / 1000)
        let s = Int(-started.timeIntervalSinceNow)
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }
}

private extension SessionProgress {
    /// False for the all-nil value `SessionProgress.read` returns when a
    /// transcript can't be matched or opened — that case keeps the row's
    /// existing single-line rendering, no placeholder second line.
    var hasProgressSignal: Bool {
        nowDoing != nil || todos != nil || retrying
            || (lastActivityAt.map { -$0.timeIntervalSinceNow > 120 } ?? false)
    }
}

/// The row's second line: what a session is doing right now, per
/// `SessionProgress` — zero-token, read from the transcript tail.
private struct SessionProgressLine: View {
    let progress: SessionProgress

    private var quietMinutes: Int? {
        guard let last = progress.lastActivityAt else { return nil }
        let idle = -last.timeIntervalSinceNow
        guard idle > 120 else { return nil }
        return Int(idle / 60)
    }

    var body: some View {
        HStack(spacing: 4) {
            statusText
            if let todos = progress.todos {
                TodoCapsule(done: todos.done, total: todos.total)
                Text(todoLabel(todos))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            if let quiet = quietMinutes {
                Text("quiet \(quiet)m")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var statusText: some View {
        if progress.retrying {
            Text("retrying")
                .font(.caption2).foregroundStyle(.orange)
        } else if let nowDoing = progress.nowDoing {
            Text(nowDoing)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
        }
    }

    private func todoLabel(_ todos: SessionProgress.Todos) -> String {
        let counts = "\(todos.done)/\(todos.total)"
        guard let activeForm = todos.activeForm else { return counts }
        return "\(counts) · \(activeForm)"
    }
}

/// Tiny (~40pt) progress capsule for a session's TodoWrite completion.
private struct TodoCapsule: View {
    let done: Int
    let total: Int

    private var fraction: CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(done) / CGFloat(total)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.25))
            Capsule().fill(Color.accentColor)
                .frame(width: 40 * fraction)
        }
        .frame(width: 40, height: 4)
    }
}
