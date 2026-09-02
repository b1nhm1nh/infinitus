import SwiftUI
import CswapCore

/// The sessions card's progress feed — the host reads Claude Code's own
/// session records + transcript tails (mac: SessionProgressModel). A host
/// without one leaves `byPid` empty and the rows keep their single line.
@MainActor
public protocol SessionProgressSource: ObservableObject {
    var byPid: [Int: SessionProgress] { get }
    /// `sessions`: the engine's current per-session detail (busy-first,
    /// capped) — only those get matched to a transcript and read.
    func refresh(sessions: [SessionDetail])
}

public extension SessionProgressSource {
    func refresh(sessions: [SessionDetail]) {}
}

/// The brain chip's click-through: every live Claude Code session with
/// status, directory, and age ("can active session be clickable and show
/// something?" — this is the something).
public struct SessionListCard<P: SessionProgressSource>: View {
    let live: LiveSessions
    @ObservedObject var progress: P

    public init(live: LiveSessions, progress: P) {
        self.live = live
        self.progress = progress
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SessionSummary.tooltip(live))
                .font(PopupFont.caption).foregroundStyle(.secondary)
            if let sessions = live.sessions, !sessions.isEmpty {
                Divider()
                ForEach(sessions, id: \.pid) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(color(for: s.status))
                                .frame(width: 7, height: 7)
                            Text(shortCwd(s.cwd))
                                .font(PopupFont.caption)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 12)
                            Text(s.status)
                                .font(PopupFont.caption).foregroundStyle(.secondary)
                            Text(age(s.startedAt))
                                .font(PopupFont.caption2).foregroundStyle(.tertiary)
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
                    .font(PopupFont.caption2).foregroundStyle(.tertiary)
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
                    .font(PopupFont.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            if let quiet = quietMinutes {
                Text("quiet \(quiet)m")
                    .font(PopupFont.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var statusText: some View {
        if progress.retrying {
            Text("retrying")
                .font(PopupFont.caption2).foregroundStyle(.orange)
        } else if let nowDoing = progress.nowDoing {
            Text(nowDoing)
                .font(PopupFont.caption2).foregroundStyle(.secondary)
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
