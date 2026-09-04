import Foundation
import InfinitusCore

/// W15: the manual half of the resume-nudge mechanism on Windows
/// (docs/plan-windows/06-nudge-resume.md). A session Claude Code stopped
/// at a usage limit is nudged back to work with a peer message — the same
/// `ResumeCoordinator` the Mac runs, with the named pipe standing in for
/// the unix socket and NO pty fallback: Windows Terminal exposes no
/// send-keys, so a session whose pipe is gone is simply unreachable.
///
/// Manual on purpose. The Mac decides WHEN to nudge from the engine's
/// quota signal (`ResumeGate`); this box runs no engine, so it can't tell
/// "quota is back" from "still limited" — it would nudge into the same
/// wall. The operator (or the phone) picks the moment; this delivers it.
enum Resume {
    /// Sessions whose transcript tail ends in a limit stop.
    static func stopped(claudeDir: URL) -> [StoppedSession] {
        Transcript.findStopped(sessions: ClaudeSessions.list(claudeDir: claudeDir),
                               claudeDir: claudeDir)
    }

    /// The coordinator wired to the pipe. `hosts: []` is the whole reason
    /// this is safe on Windows: with no pty host the coordinator's
    /// terminal fallback can't fire, so every delivery is a peer write or
    /// nothing.
    static func coordinator(claudeDir: URL) -> ResumeCoordinator {
        var coordinator = ResumeCoordinator(hosts: [], claudeDir: claudeDir)
        coordinator.socketSend = { session, text in
            guard !session.socketPath.isEmpty else { return false }
            let record = ClaudeSessions.list(claudeDir: claudeDir)
                .first { $0.pid == session.pid }
            guard let record else { return false }
            return NamedPipe.send(text: text, record: record, claudeDir: claudeDir)
        }
        return coordinator
    }
}

/// `infinitus-win resume [--pid N] [--dry-run] [--claude-dir P]` — nudge
/// every limit-stopped session, or just one. `--dry-run` lists what it
/// would nudge and writes nothing.
func resume(_ args: [String]) -> Int32 {
    var pid: Int32?, dryRun = false, claudeDir = ClaudeSessions.configHome()
    var index = args.startIndex
    while index < args.endIndex {
        switch args[index] {
        case "--pid":
            index += 1
            guard index < args.endIndex, let parsed = Int32(args[index]) else {
                fail("resume: --pid needs a number")
            }
            pid = parsed
        case "--claude-dir":
            index += 1
            guard index < args.endIndex else { fail("resume: --claude-dir needs a path") }
            claudeDir = URL(fileURLWithPath: args[index])
        case "--dry-run": dryRun = true
        default:
            fail("resume: unknown flag \(args[index])")
        }
        index += 1
    }

    var stopped = Resume.stopped(claudeDir: claudeDir)
    if let pid { stopped = stopped.filter { $0.pid == pid } }
    guard !stopped.isEmpty else {
        print("nothing stopped at a usage limit")
        return 0
    }

    if dryRun {
        for session in stopped {
            let reachable = session.socketPath.isEmpty ? "no pipe"
                : (NamedPipe.isListening(session.socketPath) ? "pipe" : "pipe gone")
            print("\(session.pid) \(session.name ?? "unnamed") — \(reachable) — \(session.cwd)")
        }
        return 0
    }

    let outcome = Resume.coordinator(claudeDir: claudeDir).resume(stopped)
    for session in outcome.accepted {
        print("nudged \(session.pid) (\(outcome.channel[session.sessionId] ?? "peer"))")
    }
    for session in outcome.unreachable {
        print("unreachable \(session.pid) — no peer channel (Windows has no send-keys fallback)")
    }
    return outcome.unreachable.isEmpty ? 0 : 1
}
