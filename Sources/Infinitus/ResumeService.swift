import SwiftUI
import CswapCore

/// The resume-nudge mechanism, app-side (user 2026-08-30: "move all the
/// nudge mechanism to Infinitus" — upstream never merged the engine's
/// copy). Reads Claude Code's own session records and transcripts, types
/// into the terminal hosting a stopped session (cmux/tmux/herdr) with the
/// peer socket as fallback, and re-arms `/rc` after a switch. Off by
/// default; per-machine (the terminals are).
@MainActor
final class ResumeService: ObservableObject {
    @Published var resumeEnabled: Bool {
        didSet { defaults.set(resumeEnabled, forKey: "resume_stopped_sessions") }
    }
    @Published var rearmEnabled: Bool {
        didSet { defaults.set(rearmEnabled, forKey: "rearm_remote_control") }
    }
    /// Sessions whose terminal saw no activity for longer are left alone
    /// by the `/rc` sweep; 0 sweeps every one.
    @Published var rearmActiveWithinMinutes: Int {
        didSet { defaults.set(rearmActiveWithinMinutes, forKey: "rearm_active_within_minutes") }
    }
    @Published private(set) var lastResult: String?
    /// Multiplexers found at launch, for the pane caption.
    let hostNames: [String]

    /// Event-log sink, wired by AppModel: (SF Symbol, text).
    var log: ((String, String) -> Void)?

    private let defaults = UserDefaults.standard
    private let claudeDir = ClaudeSessions.configHome()
    private var busy = false
    /// Stop uuids already nudged. A stop that still stands after our best
    /// effort (held for review, burned twice) is never retried — only a NEW
    /// stop is, so a held message can't be queued twice.
    private var nudged: Set<String> = []

    init() {
        resumeEnabled = defaults.object(forKey: "resume_stopped_sessions") as? Bool ?? false
        rearmEnabled = defaults.object(forKey: "rearm_remote_control") as? Bool ?? false
        rearmActiveWithinMinutes = defaults.object(forKey: "rearm_active_within_minutes") as? Int ?? 120
        hostNames = PtyHosts.available().map(\.name)
    }

    /// Called on every snapshot. `switched`: the active account changed
    /// (display-feed diff, so manual and parked-engine switches count);
    /// `activeAlive`: the account we are on can take work — the only state
    /// in which a nudge helps. Blocking work runs detached; single-flight.
    func tick(switched: Bool, activeAlive: Bool) {
        let doRearm = switched && rearmEnabled
        let doResume = resumeEnabled && activeAlive
        guard doRearm || doResume, !busy else { return }
        busy = true
        let claudeDir = claudeDir
        let activeWithin = TimeInterval(rearmActiveWithinMinutes) * 60
        let already = nudged
        Task.detached(priority: .utility) { [weak self] in
            let hosts = PtyHosts.available()
            let sessions = ClaudeSessions.list(claudeDir: claudeDir)
            var sweep: PtyNudge.SweepResult?
            if doRearm {
                // The app may run from inside a session (run-unbundled.sh
                // from a Claude Code shell): never type into our own lineage.
                let selfPids = Set(ProcessFacts.ancestors(of: getpid()))
                sweep = PtyNudge.rearmRemoteControl(
                    hosts: hosts, sessions: sessions, selfPids: selfPids,
                    activeWithin: activeWithin, confirm: true)
            }
            var outcome: ResumeCoordinator.Outcome?
            var standing: [String] = []
            if doResume {
                let stopped = Transcript.findStopped(sessions: sessions, claudeDir: claudeDir)
                    .filter { !already.contains($0.stopUuid) }
                if !stopped.isEmpty {
                    outcome = ResumeCoordinator(hosts: hosts, claudeDir: claudeDir).resume(stopped)
                    // Whatever still shows a limit stop after our best
                    // effort is remembered so the next tick leaves it alone.
                    standing = Transcript.findStopped(sessions: sessions, claudeDir: claudeDir)
                        .map(\.stopUuid).filter { !$0.isEmpty }
                }
            }
            await self?.finish(sweep: sweep, outcome: outcome, standing: standing)
        }
    }

    private func finish(sweep: PtyNudge.SweepResult?, outcome: ResumeCoordinator.Outcome?,
                        standing: [String]) {
        busy = false
        nudged.formUnion(standing)
        var lines: [String] = []
        if let sweep, !sweep.isEmpty {
            var text = "re-armed /rc on \(sweep.sent.count) session(s)"
            if !sweep.confirmed.isEmpty { text += ", \(sweep.confirmed.count) confirmed" }
            if sweep.skippedIdle > 0 { text += ", \(sweep.skippedIdle) idle skipped" }
            if sweep.noSurface > 0 { text += ", \(sweep.noSurface) without a terminal" }
            log?("antenna.radiowaves.left.and.right", text)
            lines.append(text)
        }
        if let outcome {
            for session in outcome.accepted {
                let via = outcome.channel[session.sessionId] ?? "?"
                log?("play.circle", "resumed \(session.sessionId.prefix(8)) via \(via)")
            }
            if !outcome.accepted.isEmpty {
                let text = "resumed \(outcome.accepted.count) stopped session(s)"
                Notifier.post(title: "Infinitus", body: text)
                lines.append(text)
            }
            if !outcome.unreachable.isEmpty {
                let text = "\(outcome.unreachable.count) stopped session(s) unreachable (no terminal, no socket, or mid-turn)"
                log?("play.slash", text)
                lines.append(text)
            }
        }
        if !lines.isEmpty {
            lastResult = lines.joined(separator: " · ")
        }
    }
}

/// Engines-pane section: the app-side switches. Sits above the Claude
/// Code-side reliability rows, which gate deliverability for any sender.
struct ResumeNudgesSection: View {
    @ObservedObject var service: ResumeService

    private var hostsCaption: String {
        service.hostNames.isEmpty
            ? "No terminal multiplexer found (cmux, tmux, herdr) — only the peer socket can reach a session."
            : "Terminals: \(service.hostNames.joined(separator: ", ")); the peer socket is the fallback."
    }

    var body: some View {
        Section("Resume nudges — Infinitus side") {
            Toggle("Resume sessions a usage limit stopped", isOn: $service.resumeEnabled)
                .help("When the active account can take work again, type a "
                      + "short message into every Claude Code session whose "
                      + "last turn was a plan-limit stop, so it continues "
                      + "where it left off.")
            Toggle("Re-arm Remote Control (/rc) after a switch", isOn: $service.rearmEnabled)
                .help("Type /rc into the terminal of every live session "
                      + "after the active account changes, so Remote "
                      + "Control follows the new credentials.")
            Stepper(value: $service.rearmActiveWithinMinutes, in: 0...1440, step: 15) {
                Text(service.rearmActiveWithinMinutes == 0
                     ? "Sweep every session, however idle"
                     : "Only sessions active within \(service.rearmActiveWithinMinutes) min")
            }
            .disabled(!service.rearmEnabled)
            Text(hostsCaption + " If a local claude-swap fork still carries "
                 + "autoswitch.resumeStoppedSessions / rearmRemoteControl, "
                 + "turn those off — two senders nudge twice.")
                .font(.caption).foregroundStyle(.secondary)
            if let last = service.lastResult {
                Text("Last run: \(last)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
