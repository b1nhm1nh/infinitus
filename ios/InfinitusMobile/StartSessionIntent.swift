import AppIntents
import InfinitusCore

/// Siri / Spotlight / Shortcuts: "Start a session in Infinitus" (#91,
/// the "run a speed test" card the user pointed at). The repository is
/// matched by folder name against what the Mac has run lately, else
/// taken as a path.
struct StartSessionIntent: AppIntent {
    static let title: LocalizedStringResource = "Start a session"
    static let description = IntentDescription("Opens a new Claude Code session in a repository on your Mac.")

    @Parameter(title: "Repository")
    var repo: String

    @Parameter(title: "First prompt")
    var prompt: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let recent = await MainActor.run { MirrorModel.shared.recentCwds }
        let wanted = repo.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cwd = recent.first { ($0 as NSString).lastPathComponent.lowercased() == wanted } ?? repo
        let reply = try await NetworkFleetMirror.shared.startSession(
            SessionStart.Request(cwd: cwd, engine: "claude", prompt: prompt))
        guard reply.outcome == "started" else { throw StartSessionError(message: reply.detail ?? reply.outcome) }
        if let pid = reply.pid {
            await MainActor.run {
                MirrorModel.shared.requestedPid = pid
                MirrorModel.shared.requestedTab = "sessions"
            }
        }
        let name = (cwd as NSString).lastPathComponent
        return .result(dialog: "Started in \(name)\(reply.host.map { " via \($0)" } ?? "").")
    }
}

struct StartSessionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct InfinitusShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartSessionIntent(),
                    phrases: ["Start a session in \(.applicationName)", "Start an \(.applicationName) session"],
                    shortTitle: "Start a session", systemImageName: "terminal")
    }
}
