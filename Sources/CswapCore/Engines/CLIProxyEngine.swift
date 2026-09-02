import Foundation

// MARK: - CLIProxyAPI behind the AccountEngine seam (#8)
//
// Everything goes over the proxy's Management API (`/v0/management/…`,
// bearer key). Never its config file, never its auth files — the same
// isolation cswap gets, HTTP instead of a subprocess. Portable: no
// AppKit, so the phone could talk to a proxy on the LAN one day.
//
// Verified live 2026-09-02 against cliproxyapi 7.2.145 (brew): root
// answers 200, management routes answer 401 without the key (the 81e1b53
// research note said 404 — that is the no-key-configured case), and
// `/api-call` relays Anthropic's 401 "OAuth access token has expired"
// for a stale credential, which maps to the relogin_required row.

public actor CLIProxyEngine: AccountEngine {
    public static let engineID = "cliproxy"
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:8317")!

    public nonisolated let id = CLIProxyEngine.engineID
    public nonisolated var displayName: String { "CLIProxyAPI" }
    public nonisolated var capabilities: EngineCapabilities {
        [.switch, .hold, .rename, .remove, .addOAuth, .costReport]
    }

    let baseURL: URL
    private let key: String
    private let session: URLSession
    private let ledger: ProxyUsageLedger?
    /// Fan-out cap for the per-credential usage calls.
    private let usageConcurrency = 4
    private let usageURL = "https://api.anthropic.com/api/oauth/usage"
    private let profileURL = "https://api.anthropic.com/api/oauth/profile"

    // Last-snapshot bookkeeping: the popup speaks ordinals, the proxy
    // speaks auth-file names.
    private var ordinals: [Provider: [String]] = [:]
    private var authIndexByName: [String: String] = [:]
    private var emailByName: [String: String] = [:]
    private var priorityByName: [String: Int] = [:]
    private var profiles: [String: (profile: ProxyProfile, at: Date)] = [:]
    /// Per-credential usage backoff after a 429 (Retry-After or 5 min).
    private var usageBackoff: [String: Date] = [:]
    private var pendingOAuth: (state: String, provider: Provider)?
    /// `GET /routing/strategy` as of the last snapshot.
    public private(set) var routingStrategy: String?

    public init(baseURL: URL = CLIProxyEngine.defaultBaseURL, managementKey: String,
                session: URLSession = .shared, ledgerURL: URL? = nil) {
        self.baseURL = baseURL
        self.key = managementKey
        self.session = session
        self.ledger = ledgerURL.map { ProxyUsageLedger(url: $0) }
    }

    // MARK: HTTP

    private struct Envelope: Decodable {
        let statusCode: Int
        let body: String
        enum CodingKeys: String, CodingKey { case statusCode = "status_code", body }
    }

    private func request(_ method: String, _ path: String,
                         query: [String: String] = [:],
                         json: [String: Any]? = nil) async throws -> (Int, Data) {
        var comps = URLComponents(url: baseURL.appendingPathComponent("v0/management/" + path),
                                  resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 5
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
            req.timeoutInterval = 20   // api-call relays an upstream round-trip
        }
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw EngineError.unreachable(error.localizedDescription)
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 404 { throw EngineError.unauthorized }
        guard (200..<300).contains(status) else {
            throw EngineError.remote(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return (status, data)
    }

    /// `POST /api-call`: the proxy substitutes `$TOKEN$` with the
    /// credential's access token, so the token never reaches us.
    private func apiCall(authIndex: String, url: String) async throws -> Envelope {
        let (_, data) = try await request("POST", "api-call", json: [
            "auth_index": authIndex,
            "method": "GET",
            "url": url,
            "header": [
                "Authorization": "Bearer $TOKEN$",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "infinitus/1.0",
            ],
        ])
        return try JSONDecoder().decode(Envelope.self, from: data)
    }

    // MARK: snapshot

    /// What the pane's "Test connection" shows.
    public struct Probe: Sendable, Equatable {
        public let credentialFiles: Int
        public let strategy: String?
    }

    public func probe() async throws -> Probe {
        let (_, data) = try await request("GET", "auth-files")
        let files = try JSONDecoder().decode(ProxyAuthFileList.self, from: data).files
        return Probe(credentialFiles: files.count, strategy: try? await fetchStrategy())
    }

    private func fetchStrategy() async throws -> String {
        let (_, data) = try await request("GET", "routing/strategy")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["strategy"] as? String) ?? ""
    }

    private enum UsageOutcome { case ok(Usage?), expired, failed }

    public func snapshot() async throws -> [EngineFleet] {
        let now = Date()
        let (_, data) = try await request("GET", "auth-files")
        let files = try JSONDecoder().decode(ProxyAuthFileList.self, from: data).files
        routingStrategy = try? await fetchStrategy()

        // Gauges: only Claude credentials expose oauth/usage; held ones
        // are skipped (nothing routes to them, and the poll budget is
        // per account — see cswap's poll_policy).
        let wanted = files.filter {
            ProxyMapping.provider(for: $0.provider ?? "") == .claude
                && $0.disabled != true
                && (usageBackoff[$0.name].map { $0 <= now } ?? true)
        }
        var usage: [String: Usage] = [:]
        var expired: Set<String> = []
        await withTaskGroup(of: (String, UsageOutcome, ProxyProfile?).self) { group in
            var pending = wanted.makeIterator()
            var inFlight = 0
            func launch(_ file: ProxyAuthFile) {
                let name = file.name, authIndex = file.authIndex ?? file.id ?? file.name
                let wantProfile = profiles[name].map { now.timeIntervalSince($0.at) > 86_400 } ?? true
                group.addTask { [self] in
                    guard let env = try? await self.apiCall(authIndex: authIndex, url: self.usageURL) else {
                        return (name, .failed, nil)
                    }
                    switch env.statusCode {
                    case 200:
                        let parsed = OAuthUsage.parse(Data(env.body.utf8), now: now)
                        var profile: ProxyProfile?
                        if wantProfile,
                           let p = try? await self.apiCall(authIndex: authIndex, url: self.profileURL),
                           p.statusCode == 200 {
                            profile = ProxyProfile.parse(Data(p.body.utf8))
                        }
                        return (name, .ok(parsed), profile)
                    case 401:
                        return (name, .expired, nil)
                    case 429:
                        await self.noteBackoff(name: name)
                        return (name, .failed, nil)
                    default:
                        return (name, .failed, nil)
                    }
                }
                inFlight += 1
            }
            while inFlight < usageConcurrency, let next = pending.next() { launch(next) }
            for await (name, outcome, profile) in group {
                inFlight -= 1
                switch outcome {
                case .ok(let u): if let u { usage[name] = u }
                case .expired: expired.insert(name)
                case .failed: break
                }
                if let profile { profiles[name] = (profile, now) }
                if let next = pending.next() { launch(next) }
            }
        }

        let mapped = ProxyMapping.fleets(
            engineID: Self.engineID, files: files, usage: usage,
            profiles: profiles.mapValues(\.profile), now: now)
        ordinals = mapped.ordinals
        authIndexByName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.authIndex ?? $0.id ?? $0.name) })
        emailByName = Dictionary(uniqueKeysWithValues: files.compactMap { f in f.email.map { (f.name, $0) } })
        priorityByName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.priority ?? 0) })

        await drainUsageQueue()

        // An expired token is a re-login, not an outage: the row gets the
        // relogin action instead of an error line.
        guard !expired.isEmpty else { return mapped.fleets }
        return mapped.fleets.map { fleet in
            let names = ordinals[fleet.provider] ?? []
            let accounts = fleet.accounts.map { a -> Account in
                guard a.number - 1 < names.count, expired.contains(names[a.number - 1]) else { return a }
                return Account(number: a.number, email: a.email,
                               organizationName: a.organizationName,
                               organizationUuid: a.organizationUuid,
                               isOrganization: a.isOrganization, active: a.active,
                               usageStatus: "relogin_required", usage: nil,
                               alias: a.alias, icon: a.icon, plan: a.plan,
                               disabled: a.disabled)
            }
            // A credential that needs a re-login can't be "next".
            var next = fleet.nextCandidate
            if let n = next, accounts.first(where: { $0.number == n })?.usageStatus == "relogin_required" {
                next = accounts.first {
                    !$0.active && $0.disabled != true && $0.usageStatus == "ok"
                        && !AccountVitals.isDead($0.usage)
                }?.number
            }
            return EngineFleet(engineID: fleet.engineID, provider: fleet.provider,
                               accounts: accounts, activeNumber: fleet.activeNumber,
                               nextCandidate: next,
                               nextRecovery: fleet.nextRecovery,
                               liveSessions: nil, raw: nil)
        }
    }

    private func noteBackoff(name: String) {
        usageBackoff[name] = Date().addingTimeInterval(300)
    }

    /// The proxy's usage queue is a destructive 60-second buffer: every
    /// poll pops what accumulated into our own ledger.
    private func drainUsageQueue() async {
        guard let ledger else { return }
        guard let (_, data) = try? await request("GET", "usage-queue", query: ["count": "500"]) else { return }
        let records = ProxyUsageRecord.decodeQueue(data)
        guard !records.isEmpty else { return }
        try? await ledger.append(records)
    }

    // MARK: actions

    private func name(_ provider: Provider, _ number: Int) throws -> String {
        let names = ordinals[provider] ?? []
        guard number >= 1, number <= names.count else {
            throw EngineError.remote(status: 0, body: "no account #\(number) in the last snapshot")
        }
        return names[number - 1]
    }

    /// "Switch" on a proxy = make this credential the top priority tier
    /// (selector.go: highest integer wins). Meaningful under fill-first.
    public func switchTo(fleet: Provider, number: Int) async throws {
        let target = try name(fleet, number)
        let top = priorityByName.values.max() ?? 0
        _ = try await request("PATCH", "auth-files/fields",
                              json: ["name": target, "priority": top + 1])
        priorityByName[target] = top + 1
    }

    public func setHold(fleet: Provider, number: Int, held: Bool) async throws {
        let target = try name(fleet, number)
        _ = try await request("PATCH", "auth-files/status",
                              json: ["name": target, "disabled": held])
    }

    public func rename(fleet: Provider, number: Int, _ alias: String) async throws {
        let target = try name(fleet, number)
        _ = try await request("PATCH", "auth-files/fields",
                              json: ["name": target,
                                     "note": alias.trimmingCharacters(in: .whitespaces)])
    }

    public func remove(fleet: Provider, number: Int) async throws {
        let target = try name(fleet, number)
        _ = try await request("DELETE", "auth-files", query: ["name": target])
    }

    /// The proxy runs its own OAuth callback server; we open the URL
    /// and poll the session state.
    public func beginOAuthAdd(fleet: Provider) async throws -> URL {
        let path: String
        switch fleet {
        case .claude: path = "anthropic-auth-url"
        case .codex: path = "codex-auth-url"
        case .gemini, .other: throw EngineError.unsupported("addOAuth for \(fleet.rawValue)")
        }
        let (_, data) = try await request("GET", path)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let urlString = obj?["url"] as? String, let url = URL(string: urlString),
              let state = obj?["state"] as? String else {
            throw EngineError.remote(status: 200, body: String(decoding: data, as: UTF8.self))
        }
        pendingOAuth = (state, fleet)
        return url
    }

    public func awaitOAuthAdd() async throws {
        guard let pending = pendingOAuth else { throw EngineError.unsupported("no OAuth in progress") }
        defer { pendingOAuth = nil }
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            let (_, data) = try await request("GET", "get-auth-status", query: ["state": pending.state])
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            switch obj?["status"] as? String {
            case "ok": return
            case "error":
                throw EngineError.remote(status: 200, body: (obj?["error"] as? String) ?? "OAuth failed")
            default:
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        throw EngineError.remote(status: 0, body: "OAuth sign-in timed out (5 min)")
    }

    public func usageReport(days: Int) async throws -> UsageReport {
        guard let ledger else { throw EngineError.unsupported("costReport") }
        var numbers: [String: Int] = [:], emails: [String: String] = [:]
        for (provider, names) in ordinals where provider == .claude {
            for (i, n) in names.enumerated() {
                if let idx = authIndexByName[n] {
                    numbers[idx] = i + 1
                    if let e = emailByName[n] { emails[idx] = e }
                }
            }
        }
        return await ledger.report(days: days, numbers: numbers, emails: emails)
    }
}
