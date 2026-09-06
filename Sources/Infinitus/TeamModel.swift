import AppKit
import SwiftUI
import os
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
    /// `roster/team.json` as last loaded, signed; `nil` outside a team. Set in `load()`.
    @Published private(set) var roster: Signed<TeamRoster>?
    /// A 2 s LAN browse's discoverable results (spec §6.4), on demand only.
    @Published private(set) var nearby: [TeamNearby.Peer] = []
    /// Leaders: LAN requests parked under the team (never reached the requests branch).
    @Published private(set) var pendingNearby: [Signed<TeamRequest>] = []
    @Published private(set) var scanning = false
    /// Nearby discoverability (spec §6.4): kept in `defaults` so
    /// `infinitusctl team-discoverable` and MirrorServer's
    /// `UserDefaults.didChangeNotification` observer see the same flag.
    @Published var discoverable: Bool {
        didSet { defaults.set(discoverable, forKey: TeamNearby.discoverableDefaultsKey) }
    }
    /// Approve requests that prove one of this leader's invite nonces
    /// (spec §6.2) without a tap. On by default; the proof is bound to
    /// the requester's kid (#161), so a copied request cannot ride an
    /// invite.
    @Published private(set) var autoApprove: Bool
    static let autoApproveKey = "team.autoApprove"

    /// False in mock / playground instances: every action is a no-op.
    var enabled = true
    /// Set by AppModel: the biometric-lock verdict for create / join / approve (spec §2.2).
    var gate: () -> TeamGate.Verdict = { .allowed }
    /// Set by AppModel: what this Mac publishes (projects dir, live sessions, crashes, fleets, blockers).
    var sources: () -> TeamPublisher.Sources = { TeamPublisher.Sources(projectsDir: URL(fileURLWithPath: "/nonexistent"), home: NSHomeDirectory()) }
    var showSettings: (() -> Void)?

    let paths: TeamPaths
    let makeSecrets: @Sendable () -> TeamSecrets
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "run.infinitus.team", qos: .utility)
    private var lastLoop: Date?
    private var loopRunning = false
    private var lastFetchAt: Int?
    private var lastPublishAt: Int?

    init(paths: TeamPaths, makeSecrets: @escaping @Sendable () -> TeamSecrets, defaults: UserDefaults) {
        self.paths = paths
        self.makeSecrets = makeSecrets
        self.defaults = defaults
        autoApprove = defaults.object(forKey: Self.autoApproveKey) as? Bool ?? true
        discoverable = defaults.bool(forKey: TeamNearby.discoverableDefaultsKey)
    }

    func setAutoApprove(_ on: Bool) {
        autoApprove = on
        defaults.set(on, forKey: Self.autoApproveKey)
    }

    var inTeam: Bool { snapshot != nil }
    var isLeader: Bool { snapshot?.role == "leader" }
    var policy: TeamRoster.Policy? { roster?.doc.policy }

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
        if (error as? TeamIdentityExport.ExportError) == .badPassphrase { return "wrong passphrase" }
        if let nearby = error as? TeamNearby.Client.ClientError {
            switch nearby {
            case .notALeader: return "that machine leads no team"
            case .keyMismatch(let s): return "the leader is not answering \(TeamNearby.keyPath) (\(s))"
            case .refused(let s): return "the leader refused the request (\(s))"
            case .unavailable: return "nearby discovery is not built for this platform yet"
            }
        }
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
                let result: (TeamSnapshot?, TeamReader?, TeamShares, TeamExclusions, String?, Signed<TeamRoster>?, [Signed<TeamRequest>]) = try await run { paths, secrets in
                    // Non-creating: showing a kid must never mint (and, on
                    // a denied keychain read, clobber) an identity that
                    // exists but the process could not decrypt.
                    let kid = secrets.read(TeamClient.identitySecretName).flatMap { try? TeamIdentity(secret: $0) }?.kid
                    let exclusions = TeamExclusions.load(paths: paths)
                    guard let client = try Self.openClient(paths, secrets) else { return (nil, nil, TeamShares(), exclusions, kid, nil, []) }
                    let (snap, reader) = try Self.snapshot(client, lastFetch: fetch, lastPublish: publish, lastError: err)
                    let pendingNearby = client.isLeader ? TeamNearby.Store.pending(team: client.config.id, paths: paths) : []
                    return (snap, reader, TeamShares.load(teamDir: paths.teamDir(client.config.id)), exclusions, kid, client.roster, pendingNearby)
                }
                withAnimation(.easeInOut(duration: 0.2)) {
                    snapshot = result.0; reader = result.1; shares = result.2; exclusions = result.3; kid = result.4
                    roster = result.5; pendingNearby = result.6
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
        let auto = autoApprove
        let aggregatesDue = lastAggregatesAt.map { Int(Date().timeIntervalSince1970) - $0 >= Self.aggregatesInterval } ?? true
        do {
            let (fetched, published, report, aggregated) = try await run { paths, secrets in
                guard let client = try Self.openClient(paths, secrets) else { return (nil as Int?, nil as Int?, nil as TeamPublisher.Report?, false) }
                _ = try client.fetch()
                let fetched = Int(Date().timeIntervalSince1970)
                if auto { try Self.autoApprove(client, paths: paths) }
                var published: Int?
                var report: TeamPublisher.Report?
                var aggregated = false
                if publish, client.isMember {
                    var s = sources
                    s.cacheURL = paths.teamDir(client.config.id).appendingPathComponent("scan-cache.json")
                    report = try TeamPublisher(client: client, paths: paths).publish(sources: s)
                    published = Int(Date().timeIntervalSince1970)
                    if aggregatesDue, client.isLeader {
                        // Don't let an aggregates-only failure erase the
                        // publish that just succeeded; retry next tick
                        // since `aggregated` stays false.
                        do { try Self.publishAggregates(client); aggregated = true }
                        catch { Lifecycle.log.error("aggregates publish: \(Self.mask(error), privacy: .public)") }
                    }
                }
                return (fetched, published, report, aggregated)
            }
            if let fetched { lastFetchAt = fetched }
            if let published { lastPublishAt = published }
            if let report { lastReport = report }
            if aggregated { lastAggregatesAt = Int(Date().timeIntervalSince1970) }
            lastError = nil
            await load().value
            return true
        } catch {
            lastError = Self.mask(error)
            await load().value
            return false
        }
    }

    /// Leaders: approve every pending request whose nonce is in the
    /// invite book (one round trip, no tap); each nonce is spent once.
    /// The book is saved after the prune and after every consumed nonce
    /// (not once at the end), so one request's failure can't leave an
    /// already-approved member's nonce looking unspent on disk; that
    /// request's error is swallowed (left for a manual Approve) instead
    /// of aborting the rest of the pass.
    private nonisolated static func autoApprove(_ client: TeamClient, paths: TeamPaths) throws {
        guard client.isLeader else { return }
        let dir = paths.teamDir(client.config.id)
        var book = TeamInvites.load(teamDir: dir)
        let now = Int(Date().timeIntervalSince1970)
        let before = book.nonces
        book.prune(now: now)
        if book.nonces != before { try book.save(teamDir: dir) }
        for request in try client.requests() {
            guard let nonce = book.matches(request.doc, now: now) else { continue }
            do { try client.approve(kid: request.doc.keys.kid, now: now) }
            catch is TeamClient.ClientError { continue }
            book.consume(nonce)
            try book.save(teamDir: dir)
        }
    }

    /// Spec §7: `now.json` is deleted on quit, so teammates stop seeing
    /// this Mac "on". Only when this run published (nothing else put a
    /// `now.json` there — deleting an absent path would push an empty
    /// commit). Bounded: the team queue is serial, so a loop pass mid-push
    /// could hold this for as long as git does; termination waits at most
    /// `quitBound` and the child dies with the app.
    static let quitBound: TimeInterval = 5
    func quit() async {
        guard enabled, inTeam, lastPublishAt != nil else { return }
        let paths = self.paths, makeSecrets = self.makeSecrets
        let fired = OSAllocatedUnfairLock(initialState: false)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // Whichever comes first resumes; the other finds `fired` set.
            let finish: @Sendable () -> Void = {
                let first = fired.withLock { f -> Bool in if f { return false }; f = true; return true }
                if first { cont.resume() }
            }
            queue.async {
                if let client = try? Self.openClient(paths, makeSecrets()), client.isMember {
                    try? TeamPublisher(client: client, paths: paths).quit()
                }
                finish()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.quitBound, execute: finish)
        }
    }

    // MARK: insights (spec §8.3/§8.4)

    struct Insights: Equatable {
        var rows: [TeamInsights.MemberRow]
        var repos: [TeamInsights.RepoRow]
        var cost: TeamInsights.Cost
        var blockers: [TeamInsights.Blocker]
        var hours: [Int]
        var onNow: [String]
    }

    /// Leader insights (spec §8.3) over the reader `load()` already
    /// built — a few dictionary folds, fine on the main actor.
    func insights(period: Stats.Period) -> Insights? {
        guard let reader, isLeader else { return nil }
        let rows = TeamInsights.comparison(reader, period: period)
        let repos = TeamInsights.repos(reader, period: period)
        return Insights(rows: rows, repos: repos, cost: TeamInsights.cost(rows, repos: repos),
                        blockers: TeamInsights.blockers(reader), hours: TeamInsights.hours(rows),
                        onNow: TeamInsights.whoIsOn(reader).map(\.name))
    }

    func sharedWithMe() -> [TeamInsights.ShareRow] {
        guard let reader, let roster, let kid else { return [] }
        return TeamInsights.sharedWithMe(reader, roster: roster.doc, me: kid)
    }

    // MARK: nearby (spec §6.4)

    /// A 2 s mDNS browse on the team queue (spec §6.4). On demand only —
    /// the section's Scan button and its first appearance — never a timer.
    func scanNearby() async {
        guard enabled, !scanning else { return }
        scanning = true
        defer { scanning = false }
        do {
            let me = kid
            let peers = try await run { _, _ in try TeamNearby.Client.browse(seconds: 2) }
            nearby = peers.filter { $0.discoverable && $0.kid != me }
        } catch { lastError = Self.mask(error) }
    }

    func requestNearby(_ peer: TeamNearby.Peer, name: String) async {
        guard gated() else { return }
        let device = Host.current().localizedName ?? "Mac"
        await action("Asking \(peer.name) to join…") { paths, secrets in
            _ = try TeamNearby.Client.request(to: peer, name: name, devices: [device], platform: "macos",
                                              paths: paths, secrets: secrets, http: Self.blockingHTTP)
        }
    }

    /// One blocking exchange with a LAN peer, run on the team queue (the
    /// same shape the CLI uses; a 10 s cap so a vanished peer can't hang
    /// the queue).
    private nonisolated static let blockingHTTP: TeamNearby.Client.HTTP = { method, host, port, path, body in
        let bracketed = host.contains(":") ? "[\(host)]" : host
        guard let url = URL(string: "http://\(bracketed):\(port)\(path)") else {
            throw NSError(domain: "team", code: 1, userInfo: [NSLocalizedDescriptionKey: "bad peer address \(host):\(port)"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 10
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let done = DispatchSemaphore(value: 0)
        let box = OSAllocatedUnfairLock<(Int, Data, Error?)>(initialState: (0, Data(), nil))
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.withLock { $0 = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data(), error) }
            done.signal()
        }.resume()
        done.wait()
        let (status, data, failure) = box.withLock { $0 }
        if let failure { throw failure }
        return (status, data)
    }

    /// Leader: a LAN request that stayed pending (the joiner had no store
    /// credential) is pushed into the requests branch so Approve works on
    /// it like any other (spec §6.4).
    func pullNearbyRequest(_ signed: Signed<TeamRequest>) async {
        await action("Filing the request…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            try TeamNearby.Store.writeToRequestsBranch(team: client.config.id, signed: signed, paths: paths, secrets: secrets)
            let pendingFile = TeamNearby.Store.pendingDir(team: client.config.id, paths: paths).appendingPathComponent("\(signed.doc.keys.kid).json")
            try? FileManager.default.removeItem(at: pendingFile)
        }
    }

    // MARK: policy + aggregates (spec §8.3)

    func setPolicy(requests: String, membersSeeEachOther: Bool) async {
        await action("Saving policy…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            try client.setPolicy(TeamRoster.Policy(requests: requests, membersSeeEachOther: membersSeeEachOther))
        }
    }

    private var lastAggregatesAt: Int?
    static let aggregatesInterval = 3_600

    /// Leaders publish `roster/aggregates/<period>.json` (spec §8.3) —
    /// hourly from the loop, or now from the pane. All four periods in
    /// one push.
    private nonisolated static func publishAggregates(_ client: TeamClient) throws {
        guard client.isLeader, let roster = client.roster?.doc else { return }
        let reader = try TeamReader.load(client: client)
        var docs: [String: Data] = [:]
        for p in Stats.Period.allCases {
            docs[p.rawValue] = try CanonicalJSON.encode(TeamInsights.aggregates(reader, roster: roster, period: p))
        }
        _ = try client.publishAggregates(docs)
    }

    func publishAggregatesNow() async {
        var ok = false
        await action("Publishing the team picture…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            try Self.publishAggregates(client)
            ok = true
        }
        if ok { lastAggregatesAt = Int(Date().timeIntervalSince1970) }
    }

    // MARK: identity (spec §2.1) — the secret is shown only as the recovery key, after Touch ID

    func recoveryKey() async -> String? {
        guard enabled else { return nil }
        switch await BiometricLock.authenticate(reason: "show your team identity's recovery key") {
        case .ok: break
        case .cancelled: return nil
        case .failed(let why): lastError = why; return nil
        }
        do {
            return try await run { paths, secrets in RecoveryKey.encode(try TeamClient.identity(paths: paths, secrets: secrets).secret) }
        } catch { lastError = Self.mask(error); return nil }
    }

    func exportIdentity(passphrase: String, to url: URL) async -> Bool {
        guard enabled, passphrase.count >= 8 else { lastError = "the passphrase needs at least 8 characters"; return false }
        var ok = false
        await action("Exporting…") { paths, secrets in
            let me = try TeamClient.identity(paths: paths, secrets: secrets)
            try TeamIdentityExport.write(try TeamIdentityExport.export(secret: me.secret, passphrase: passphrase), to: url)
            ok = true
        }
        return ok
    }

    /// Replacing the identity while in a team would orphan the membership
    /// (the roster names the old kid) — refuse; Leave first.
    private func importable() -> Bool {
        if inTeam { lastError = "leave the team before replacing this Mac's identity"; return false }
        return true
    }

    func importIdentity(recoveryKey text: String) async -> Bool {
        guard enabled, importable() else { return false }
        guard let secret = RecoveryKey.decode(text) else { lastError = "that is not a recovery key"; return false }
        var ok = false
        await action("Importing…") { _, secrets in try secrets.write(TeamClient.identitySecretName, secret); ok = true }
        return ok
    }

    func importIdentity(file url: URL, passphrase: String) async -> Bool {
        guard enabled, importable() else { return false }
        var ok = false
        await action("Importing…") { _, secrets in
            let secret = try TeamIdentityExport.import(try Data(contentsOf: url), passphrase: passphrase)
            try secrets.write(TeamClient.identitySecretName, secret)
            ok = true
        }
        return ok
    }

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

    /// A teammate's session as chat items (decrypted now, off the main actor).
    func transcript(kid: String, session: String) async -> [SessionFeedItem] {
        guard enabled else { return [] }
        do {
            return try await run { paths, secrets in
                guard let client = try Self.openClient(paths, secrets) else { return [] }
                return try TeamReader.load(client: client).transcript(kid: kid, session: session, client: client, limit: 400)
            }
        } catch {
            lastError = Self.mask(error)
            return []
        }
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

    /// An invite link (spec §6.2): a code with a one-time nonce this
    /// leader remembers and auto-approves.
    func mintInvite(days: Int) async {
        var minted: String?
        await action("Making an invite…") { paths, secrets in
            guard let client = try Self.openClient(paths, secrets) else { throw TeamClient.ClientError.notInTeam }
            _ = try client.fetch()
            let nonce = TeamInvites.newNonce()
            let expires = Int(Date().timeIntervalSince1970) + days * 86_400
            let dir = paths.teamDir(client.config.id)
            var book = TeamInvites.load(teamDir: dir)
            book.prune(now: Int(Date().timeIntervalSince1970))
            book.add(nonce: nonce, expires: expires)
            try book.save(teamDir: dir)
            minted = try client.code(expiresIn: days * 86_400, nonce: nonce)
        }
        if let minted { code = minted }
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

    /// `infinitus://join/<payload>` (spec §6.2): verified at request time
    /// by `TeamCode.decode`; here the pane just gets it prefilled. False
    /// for any other URL. Already in a team (the pane has no Join field
    /// then): says so instead of prefilling nothing — best effort, since
    /// a cold-launch replay lands before the first `load()`.
    @discardableResult
    func open(url: URL) -> Bool {
        let text = url.absoluteString
        guard text.hasPrefix(TeamCode.prefix) else { return false }
        if inTeam { lastError = "already in a team; leave it first to join another" } else { pendingCode = text }
        revealSetting()
        return true
    }

    /// Opens Settings on the Team pane (the join link lands here).
    func revealSetting() {
        showSettings?()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name("infinitus.selectPane"), object: TeamModel.paneTitle)
        }
    }
}
