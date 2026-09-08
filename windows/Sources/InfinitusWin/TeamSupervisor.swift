import Foundation
import InfinitusCore

/// The Mac's lane-4 grantor pass on the daemon's cycle: fetch the team store,
/// then `TeamControlStore.Store.grantorPass`. Off unless `serve --team-grant`
/// — this lane types into the user's sessions on a teammate's behalf.
///
/// Cadence is the Mac's 300 s, half of `TeamControl.storeTTL = 600`. Faster
/// would not shrink driver-side latency (that budget is the store lane's);
/// slower silently drops commands as expired.
final class TeamSupervisor: @unchecked Sendable {
    /// Must stay well under `TeamControl.storeTTL` or a command expires
    /// before the pass sees it. Asserted in `start` and in tests.
    static let tickSeconds: TimeInterval = 300

    /// What a tick wrote so the tray can show it without talking to the
    /// daemon. `<teamDir>/control-last-pass.json`.
    struct LastPass: Codable, Equatable, Sendable {
        var at: Int
        var answered: Int
        var lastOutcome: String?
        var lastRefusal: String?
        var error: String?

        static func file(teamDir: URL) -> URL {
            teamDir.appendingPathComponent("control-last-pass.json")
        }

        static func load(teamDir: URL) -> LastPass? {
            (try? Data(contentsOf: file(teamDir: teamDir))).flatMap {
                try? JSONDecoder().decode(LastPass.self, from: $0)
            }
        }

        func save(teamDir: URL) throws {
            try FileManager.default.createDirectory(at: teamDir, withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: Self.file(teamDir: teamDir), options: .atomic)
        }
    }

    /// What a tick decided, before git or delivery. Split out so tests can
    /// inspect the decision without a live remote.
    struct Plan: Equatable {
        var teamID: String?
        var skipped: String?
    }

    private let claudeDir: URL
    private let owned: OwnedSessionsBox
    private let log: @Sendable (String) -> Void
    private let deliverOverride: (@Sendable (SessionInput.Request, ClaudeSessionRecord) -> SessionInput.Reply?)?

    private let lock = NSLock()
    private var started = false
    private var running = false
    private var timer: DispatchSourceTimer?
    private var seen: TeamControl.SeenIDs = TeamControl.SeenIDs()
    private var limit = TeamControl.RateLimit()
    private var seenDir: URL?

    init(claudeDir: URL,
         owned: OwnedSessionsBox,
         deliverOverride: (@Sendable (SessionInput.Request, ClaudeSessionRecord) -> SessionInput.Reply?)? = nil,
         log: @escaping @Sendable (String) -> Void) {
        self.claudeDir = claudeDir
        self.owned = owned
        self.deliverOverride = deliverOverride
        self.log = log
    }

    /// Arms the tick on a background queue. Idempotent. Touches no team
    /// files until the first tick — without `--team-grant` this is never
    /// called.
    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()

        // A cadence at or above storeTTL silently drops commands as expired
        // and looks like a delivery bug. Keep this next to the constant.
        precondition(Self.tickSeconds < TimeInterval(TeamControl.storeTTL),
                     "grantor cadence \(Self.tickSeconds)s must be under storeTTL \(TeamControl.storeTTL)s")

        guard GitLocator.cachedLocate() != nil else {
            log("team-grant off: git not found — install Git for Windows")
            return
        }
        log("team-grant on: fetch + grantor pass every \(Int(Self.tickSeconds))s "
            + "(store TTL \(TeamControl.storeTTL)s)")
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + Self.tickSeconds, repeating: Self.tickSeconds)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    /// The decision for right now. Writes nothing.
    func plan(now: Date = Date(),
              teamIDs providedIDs: [String]? = nil,
              gitFound providedGit: Bool? = nil) -> Plan {
        _ = now
        let gitFound = providedGit ?? (GitLocator.cachedLocate() != nil)
        guard gitFound else {
            return Plan(skipped: "git not found — install Git for Windows")
        }
        let ids = providedIDs ?? TeamPaths.standard().teamIDs()
        guard let teamID = ids.sorted().first else {
            return Plan(skipped: "not in a team")
        }
        return Plan(teamID: teamID)
    }

    /// Fetch + `grantorPass`. `client` / `endpoint` / `handled` are injectable
    /// so a test drives the pass without a live remote.
    @discardableResult
    func apply(client: TeamClient,
               endpoint: inout TeamControl.Endpoint,
               handled: inout TeamControl.Handled,
               now: Int = Int(Date().timeIntervalSince1970)) throws -> [TeamControl.Audit] {
        try TeamControl.Store.grantorPass(client: client, endpoint: &endpoint, handled: &handled, now: now)
    }

    /// The Endpoint the pass and a test share: core's verify / SeenIDs /
    /// RateLimit, execute through `DeliveryLane`.
    func makeEndpoint(identity: TeamIdentity,
                      roster: @escaping () -> TeamRoster?,
                      grants: @escaping () -> TeamGrants,
                      liveSessions: @escaping () -> [String: Int32],
                      seen: TeamControl.SeenIDs,
                      limit: TeamControl.RateLimit,
                      now: @escaping () -> Date) -> TeamControl.Endpoint {
        let owned = self.owned
        let claudeDir = self.claudeDir
        let deliverOverride = self.deliverOverride
        return TeamControl.Endpoint(
            identity: identity,
            roster: roster,
            grants: grants,
            liveSessions: liveSessions,
            execute: { action, text, pid in
                guard let request = TeamControl.request(action: action, text: text) else {
                    return SessionInput.Reply(outcome: "rejected", detail: "nothing to run for \(action)")
                }
                return DeliveryLane.deliver(pid: pid, request: request, owned: owned,
                                            claudeDir: claudeDir, deliverOverride: deliverOverride)
            },
            seen: seen, limit: limit, now: now)
    }

    /// One pass. Runs on the timer queue — everything here may block.
    func tick(now: Date = Date(),
              teamIDs: [String]? = nil,
              gitFound: Bool? = nil) {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        defer { lock.lock(); running = false; lock.unlock() }

        let plan = plan(now: now, teamIDs: teamIDs, gitFound: gitFound)
        guard let teamID = plan.teamID else { return }

        let paths = TeamPaths.standard()
        let dir = paths.teamDir(teamID)
        let secrets = FileSecrets(dir: paths.secretsDir)
        let nowSec = Int(now.timeIntervalSince1970)
        do {
            let client = try TeamClient.open(id: teamID, paths: paths, secrets: secrets)
            _ = try client.fetch()
            lock.lock()
            if seenDir != dir { seen = TeamControl.SeenIDs.load(teamDir: dir); seenDir = dir }
            var endpoint = makeEndpoint(
                identity: client.identity,
                roster: { client.roster?.doc },
                grants: { TeamGrants.load(teamDir: dir) },
                liveSessions: {
                    Dictionary(ClaudeSessions.list(claudeDir: self.claudeDir).map { ($0.sessionId, $0.pid) },
                               uniquingKeysWith: { _, newer in newer })
                },
                seen: seen, limit: limit, now: { now })
            lock.unlock()

            var handled = TeamControl.Handled.load(teamDir: dir)
            let audits = try apply(client: client, endpoint: &endpoint, handled: &handled, now: nowSec)

            lock.lock()
            seen = endpoint.seen
            limit = endpoint.limit
            lock.unlock()
            try endpoint.seen.save(teamDir: dir)
            try handled.save(teamDir: dir)

            let lastRefusal = audits.last(where: { TeamControl.Outcome.refusals.contains($0.outcome) })?.outcome
            try LastPass(at: nowSec, answered: audits.count,
                         lastOutcome: audits.last?.outcome,
                         lastRefusal: lastRefusal, error: nil).save(teamDir: dir)

            for audit in audits {
                let name = endpoint.roster()?.everyone.first { $0.keys.kid == audit.driver }?.name
                    ?? String(audit.driver.prefix(8))
                log("team-grant: \(name) \(audit.action) \(audit.session) → \(audit.outcome)")
            }
        } catch {
            let masked = TeamGit.masked("\(error)")
            log("team-grant: \(masked)")
            try? LastPass(at: nowSec, answered: 0, lastOutcome: nil,
                          lastRefusal: nil, error: masked).save(teamDir: dir)
        }
    }
}
