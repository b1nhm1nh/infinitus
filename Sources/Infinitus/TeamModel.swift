import AppKit
import SwiftUI
import InfinitusCore

/// The app's side of a team (spec §9 Mac Team pane, §7 the loop). Every
/// git or crypto call opens a `TeamClient` on a private serial queue and
/// hands back a Sendable result; the main actor only holds the published
/// snapshot. No timer: `refreshIfStale` rides AppModel's refresh tick
/// (like StatsModel) and does a fetch + publish at most every 300 s.
/// One team per Mac in the pane (several teams stay CLI-only, `--team`).
@MainActor
final class TeamModel: ObservableObject {
    static let paneTitle = "Team"
    static let loopInterval: TimeInterval = 300

    @Published private(set) var snapshot: TeamSnapshot?
    @Published private(set) var reader: TeamReader?
    /// What a user-initiated action is doing ("Fetching…"); nil when idle.
    /// The background loop never sets it.
    @Published private(set) var busy: String?
    @Published private(set) var lastError: String?
    /// The team code or invite link minted last; shown until the pane closes it.
    @Published private(set) var code: String?
    /// The most recent publish pass's report (loop or `publishNow`); what
    /// `team-publish` replies with.
    @Published private(set) var lastReport: TeamPublisher.Report?
    @Published private(set) var shares = TeamShares()
    @Published private(set) var exclusions = TeamExclusions()
    /// My identity's kid once read (creating it on first use, like the CLI).
    @Published private(set) var kid: String?
    /// From an `infinitus://join/…` link (Task 6): the pane's Join field prefills.
    @Published var pendingCode: String?

    /// False in mock / playground instances: every action is a no-op.
    var enabled = true
    /// Set by AppModel: the biometric-lock verdict for create / join / approve (spec §2.2).
    var gate: () -> TeamGate.Verdict = { .allowed }
    /// Set by AppModel: what this Mac publishes (projects dir, live sessions, crashes, fleets, blockers).
    var sources: () -> TeamPublisher.Sources = { TeamPublisher.Sources(projectsDir: URL(fileURLWithPath: "/nonexistent"), home: NSHomeDirectory()) }
    var showSettings: (() -> Void)?

    let paths: TeamPaths
    let makeSecrets: @Sendable () -> TeamSecrets
    private let queue = DispatchQueue(label: "run.infinitus.team", qos: .utility)
    private var lastLoop: Date?
    private var loopRunning = false
    private var lastFetchAt: Int?
    private var lastPublishAt: Int?

    init(paths: TeamPaths, makeSecrets: @escaping @Sendable () -> TeamSecrets) {
        self.paths = paths
        self.makeSecrets = makeSecrets
    }

    var inTeam: Bool { snapshot != nil }
    var isLeader: Bool { snapshot?.role == "leader" }

    // MARK: background execution

    /// Runs `work` on the team queue with a fresh secrets store; the
    /// closure must open its own client (TeamClient is not Sendable).
    private func run<T: Sendable>(_ work: @escaping @Sendable (TeamPaths, TeamSecrets) throws -> T) async throws -> T {
        let paths = self.paths, makeSecrets = self.makeSecrets
        return try await withCheckedThrowingContinuation { cont in
            queue.async {
                do { cont.resume(returning: try work(paths, makeSecrets())) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    /// The single team on this Mac, or nil.
    private nonisolated static func teamID(_ paths: TeamPaths) -> String? { paths.teamIDs().sorted().first }

    private nonisolated static func openClient(_ paths: TeamPaths, _ secrets: TeamSecrets) throws -> TeamClient? {
        guard let id = teamID(paths) else { return nil }
        return try TeamClient.open(id: id, paths: paths, secrets: secrets)
    }

    private nonisolated static func today(_ calendar: Calendar = .current) -> String {
        Stats.dayKey(Date(), calendar: calendar)
    }

    /// Same intent as `TeamSnapshot.maskRemote`, for free-text errors:
    /// `TeamGit.GitError.failed` carries git's stderr verbatim, which
    /// echoes a credentialed remote (`https://user:token@host/repo.git`)
    /// on failure. Strips any `scheme://user[:pass]@` fragment rather
    /// than assuming the whole message is a bare URL.
    private nonisolated static func mask(_ error: Error) -> String {
        let message = "\(error)"
        // The userinfo itself may contain "/" (a base64-ish token), so
        // only "@", whitespace and quotes end the match — erring toward
        // masking too much rather than leaking a credential that has one.
        guard let regex = try? NSRegularExpression(pattern: "([a-zA-Z][a-zA-Z0-9+.-]*://)[^@\\s'\"]+@") else { return message }
        let range = NSRange(message.startIndex..., in: message)
        return regex.stringByReplacingMatches(in: message, range: range, withTemplate: "$1")
    }

    /// Rebuilds the snapshot from the local clone (no network): status +
    /// reader + (leaders) the request list.
    private nonisolated static func snapshot(_ client: TeamClient, lastFetch: Int?, lastPublish: Int?, lastError: String?) throws -> (TeamSnapshot, TeamReader?) {
        let status = try client.status()
        let reader = client.roster == nil ? nil : try? TeamReader.load(client: client)
        let requests = client.isLeader ? (try? client.requests()) ?? [] : []
        return (TeamSnapshot.make(status: status, roster: client.roster?.doc, reader: reader, requests: requests,
                                  today: today(), lastFetch: lastFetch, lastPublish: lastPublish, lastError: lastError), reader)
    }

    /// Every action ends here: reload the snapshot, settings and the kid.
    /// Returns the reload `Task` so an action can `await` it before
    /// replying — a control command must see the fresh snapshot.
    @discardableResult
    func load() -> Task<Void, Never> {
        guard enabled else { return Task {} }
        let fetch = lastFetchAt, publish = lastPublishAt, err = lastError
        return Task {
            do {
                let result: (TeamSnapshot?, TeamReader?, TeamShares, TeamExclusions, String?) = try await run { paths, secrets in
                    // Non-creating: showing a kid must never mint (and, on
                    // a denied keychain read, clobber) an identity that
                    // exists but the process could not decrypt.
                    let kid = secrets.read(TeamClient.identitySecretName).flatMap { try? TeamIdentity(secret: $0) }?.kid
                    let exclusions = TeamExclusions.load(paths: paths)
                    guard let client = try Self.openClient(paths, secrets) else { return (nil, nil, TeamShares(), exclusions, kid) }
                    let (snap, reader) = try Self.snapshot(client, lastFetch: fetch, lastPublish: publish, lastError: err)
                    return (snap, reader, TeamShares.load(teamDir: paths.teamDir(client.config.id)), exclusions, kid)
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    snapshot = result.0; reader = result.1; shares = result.2; exclusions = result.3; kid = result.4
                }
            } catch {
                lastError = Self.mask(error)
            }
        }
    }

    // MARK: the loop (spec §7: fetch + publish, no prompt)

    /// Called from AppModel's refresh tick. Fetches, (leaders) approves
    /// invited requests, publishes, reloads — at most once per 300 s,
    /// never overlapping, never while a user action runs.
    func refreshIfStale(_ interval: TimeInterval = TeamModel.loopInterval) {
        guard enabled, inTeam, !loopRunning, busy == nil else { return }
        if let last = lastLoop, Date().timeIntervalSince(last) < interval { return }
        lastLoop = Date()
        loopRunning = true
        let sources = self.sources()
        Task {
            defer { loopRunning = false }
            await loop(sources: sources, publish: true)
        }
    }

    /// One fetch (+ publish) pass; errors land in `lastError`, never throw
    /// to the caller. Returns whether the pass succeeded.
    @discardableResult
    private func loop(sources: TeamPublisher.Sources, publish: Bool) async -> Bool {
        do {
            let (fetched, published, report) = try await run { paths, secrets in
                guard let client = try Self.openClient(paths, secrets) else { return (nil as Int?, nil as Int?, nil as TeamPublisher.Report?) }
                _ = try client.fetch()
                let fetched = Int(Date().timeIntervalSince1970)
                try Self.autoApprove(client, paths: paths)   // Task 6 fills this in; a no-op until then
                var published: Int?
                var report: TeamPublisher.Report?
                if publish, client.isMember {
                    var s = sources
                    s.cacheURL = paths.teamDir(client.config.id).appendingPathComponent("scan-cache.json")
                    report = try TeamPublisher(client: client, paths: paths).publish(sources: s)
                    published = Int(Date().timeIntervalSince1970)
                }
                return (fetched, published, report)
            }
            if let fetched { lastFetchAt = fetched }
            if let published { lastPublishAt = published }
            if let report { lastReport = report }
            lastError = nil
            await load().value
            return true
        } catch {
            lastError = Self.mask(error)
            await load().value
            return false
        }
    }

    /// Task 6 replaces this body with the invite-nonce auto-approval.
    private nonisolated static func autoApprove(_ client: TeamClient, paths: TeamPaths) throws {}

    // MARK: user actions

    private func gated() -> Bool {
        if case .needsLock(let why) = gate() { lastError = why; return false }
        return true
    }

    /// Wraps a user action: busy label, error capture, reload.
    private func action(_ label: String, _ work: @escaping @Sendable (TeamPaths, TeamSecrets) throws -> Void) async {
        guard enabled else { lastError = "team is disabled in this instance"; return }
        busy = label
        defer { busy = nil }
        do {
            try await run(work)
            lastError = nil
        } catch {
            lastError = Self.mask(error)
        }
        await load().value
    }

    func fetchNow() async {
        guard enabled else { lastError = "team is disabled in this instance"; return }
        guard inTeam else { lastError = "not in a team"; return }
        busy = "Fetching…"; defer { busy = nil }
        await loop(sources: sources(), publish: false)
    }

    func publishNow() async {
        guard enabled else { lastError = "team is disabled in this instance"; return }
        guard inTeam else { lastError = "not in a team"; return }
        busy = "Publishing…"; defer { busy = nil }
        await loop(sources: sources(), publish: true)
    }

    func create(name: String, remote: String, token: String?, leaderName: String) async {
        guard gated() else { return }
        let token = token.flatMap { $0.isEmpty ? nil : $0 }
        await action("Creating team…") { paths, secrets in
            _ = try TeamClient.create(name: name, remote: remote, token: token, leaderName: leaderName, paths: paths, secrets: secrets)
        }
        lastLoop = Date()
    }

    func join(code: String, name: String) async {
        guard gated() else { return }
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = Host.current().localizedName ?? "Mac"
        await action("Requesting to join…") { paths, secrets in
            _ = try TeamClient.request(code: code, name: name, devices: [device], platform: "macos", paths: paths, secrets: secrets)
        }
        pendingCode = nil
    }

    /// A team code (spec §6.3): no nonce, `days` of validity.
    func mintCode(days: Int) async {
        var minted: String?
        await action("Making a code…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            minted = try client.code(expiresIn: days * 86_400)
        }
        if let minted { code = minted }
    }

    /// Task 6: mints a one-time nonce the store auto-approves. Until then
    /// it mints a plain team code (§6.3), same as `mintCode`.
    func mintInvite(days: Int) async {
        // Task 6: invite
        await mintCode(days: days)
    }

    func approve(kid: String) async {
        guard gated() else { return }
        await action("Approving…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            try client.approve(kid: kid)
        }
    }

    func decline(kid: String) async {
        await action("Declining…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            try client.decline(kid: kid)
        }
    }

    func remove(kid: String) async {
        await action("Removing…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            try client.remove(kid: kid)
        }
    }

    func promote(kid: String) async {
        await action("Promoting…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            try client.promote(kid: kid)
        }
    }

    /// Local setting (never sent): where one kind goes. Applies to the
    /// next publish; `reshare(days:)` re-wraps history on request.
    func setShare(kind: String, target: TeamRoster.ShareTarget) async {
        await action("Saving…") { paths, secrets in
            guard let id = Self.teamID(paths) else { throw TeamClient.ClientError.notInTeam }
            let dir = paths.teamDir(id)
            var shares = TeamShares.load(teamDir: dir)
            shares.byKind[kind] = target
            try shares.save(teamDir: dir)
        }
    }

    func setExcluded(_ project: String, on: Bool) async {
        let path = URL(fileURLWithPath: project).standardizedFileURL.path
        await action("Saving…") { paths, _ in
            var exclusions = TeamExclusions.load(paths: paths)
            exclusions.set(path, excluded: on)
            try exclusions.save(paths: paths)
        }
    }

    func reshare(days: Int) async {
        await action("Re-sharing…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            _ = try TeamPublisher(client: client, paths: paths).reshare(days: days)
        }
    }

    /// Spec §6.5: delete my files on the store, leave a note, forget the
    /// team locally (dir + token). The identity stays.
    func leave() async {
        await action("Leaving…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try? client.fetch()
            try client.leave()
            secrets.delete(TeamClient.tokenName(client.config.id))
            try FileManager.default.removeItem(at: paths.teamDir(client.config.id))
        }
        code = nil
    }

    func clearCode() { code = nil }
    func clearError() { lastError = nil }

    /// Opens Settings on the Team pane (the join link lands here).
    func revealSetting() {
        showSettings?()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("infinitus.selectPane"), object: TeamModel.paneTitle)
        }
    }
}
