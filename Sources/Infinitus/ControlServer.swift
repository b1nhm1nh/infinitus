import Foundation
import Network
import InfinitusCore

/// The agent-facing control socket (user 2026-09-03). A same-user UNIX
/// socket in App Support; one JSON line per connection each way. Every
/// command runs on the main actor through the same AppModel / FleetState
/// calls the panes make, so an agent sees and changes exactly what the
/// popup shows. Dispatch table = `ControlCommand.all`; a command missing
/// here answers "not implemented" rather than silently succeeding.
@MainActor
final class ControlServer {
    private unowned let model: AppModel
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "infinitus.control")
    private var busy = false
    private var task: Task<Void, Never>?

    init(model: AppModel) { self.model = model }

    func start() {
        let url = ControlProtocol.socketURL()
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A stale socket from a crashed instance must not block the bind.
        unlink(url.path)
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.unix(path: url.path)
        guard let listener = try? NWListener(using: params) else {
            NSLog("Infinitus control: couldn't open %@", url.path)
            return
        }
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            Task { @MainActor in self.serve(conn) }
        }
        listener.stateUpdateHandler = { state in
            if case .ready = state { chmod(url.path, 0o600) }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        unlink(ControlProtocol.socketURL().path)
    }

    private func serve(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, _, error in
            guard let self, let data, error == nil else { conn.cancel(); return }
            Task { @MainActor in
                let reply = await self.handle(line: data)
                let bytes = (try? ControlCodec.encode(reply)) ?? Data("{\"ok\":false}\n".utf8)
                conn.send(content: bytes, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }

    private func handle(line: Data) async -> ControlReply {
        let request: ControlRequest
        do { request = try ControlCodec.decode(ControlRequest.self, from: line) }
        catch { return .failure("bad request: \(error)") }
        guard ControlCommand.named(request.command) != nil else {
            return .failure("unknown command \(request.command); run `infinitusctl manifest`")
        }
        guard !busy else { return .failure("busy: another control command is running") }
        busy = true
        defer { busy = false }
        do { return try await dispatch(request) }
        catch { return .failure((error as? LocalizedError)?.errorDescription ?? "\(error)") }
    }

    // MARK: dispatch

    private struct Fail: LocalizedError {
        let errorDescription: String?
        init(_ m: String) { errorDescription = m }
    }

    private func dispatch(_ r: ControlRequest) async throws -> ControlReply {
        switch r.command {
        case "manifest":
            return ControlReply(ok: true, result: try .of([
                "schemaVersion": JSONValue.number(Double(ControlProtocol.schemaVersion)),
                "commands": try .of(ControlCommand.all),
            ] as [String: JSONValue]))

        case "status":
            return ControlReply(ok: true, result: try .of(status()))

        case "fleets":
            return ControlReply(ok: true, result: try .of(fleetsPayload()))

        case "refresh":
            await model.refreshSnapshot()
            return ControlReply(ok: true, result: try .of(fleetsPayload()))

        case "switch", "hold", "unhold", "rename", "remove":
            let (fleet, n) = try target(r)
            let need: EngineCapabilities = ["switch": .switch, "hold": .hold, "unhold": .hold,
                                            "rename": .rename, "remove": .remove][r.command]!
            guard fleet.capabilities.contains(need) else {
                throw Fail("\(fleet.id) does not support \(r.command)")
            }
            guard fleet.accounts.contains(where: { $0.number == n }) else {
                throw Fail("no account #\(n) in \(fleet.id)")
            }
            switch r.command {
            case "switch": try await fleet.engine.switchTo(fleet: fleet.provider, number: n)
            case "hold": try await fleet.engine.setHold(fleet: fleet.provider, number: n, held: true)
            case "unhold": try await fleet.engine.setHold(fleet: fleet.provider, number: n, held: false)
            case "rename":
                guard r.args.count >= 3 else { throw Fail("usage: rename <fleet> <n> <alias>") }
                try await fleet.engine.rename(fleet: fleet.provider, number: n, r.args[2])
            case "remove":
                guard r.options["yes"] != nil else { throw Fail("remove deletes the credential; pass --yes") }
                try await fleet.engine.remove(fleet: fleet.provider, number: n)
            default: break
            }
            await model.refreshSnapshot()
            return ControlReply(ok: true, result: try .of(["fleet": fleetPayload(fleet)]))

        case "add":
            guard let key = r.args.first,
                  let fleet = model.fleets.first(where: { $0.id == key }) else {
                throw Fail("usage: add <fleet>; fleets: \(model.fleets.map(\.id).joined(separator: ", "))")
            }
            guard !TokenFlow.shared.running, !model.addingFirstAccount else {
                throw Fail("a sign-in is already running")
            }
            if fleet.capabilities.contains(.addOAuth) {
                model.addOAuthAccount(engineID: fleet.engineID, provider: fleet.provider)
            } else if fleet.engineID == CswapEngine.engineID {
                model.addFirstAccount()
            } else {
                throw Fail("\(key) has no sign-in flow")
            }
            return ControlReply(ok: true, result: .object(["started": .bool(true)]))

        case "wait-add":
            let timeout = Double(r.options["timeout"] ?? "") ?? 300
            let deadline = Date().addingTimeInterval(timeout)
            while (TokenFlow.shared.running || model.addingFirstAccount), Date() < deadline {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            let stillRunning = TokenFlow.shared.running || model.addingFirstAccount
            let error = model.firstAccountMessage
            return ControlReply(ok: !stillRunning && error == nil, result: try .of([
                "done": JSONValue.bool(!stillRunning),
                "error": error.map(JSONValue.string) ?? (stillRunning ? .string("timed out") : .null),
                "fleets": try .of(fleetsPayload()),
            ] as [String: JSONValue]), error: stillRunning ? "timed out after \(Int(timeout))s" : error)

        case "engine":
            guard r.args.count == 2, ["on", "off"].contains(r.args[1]) else {
                throw Fail("usage: engine cswap|cliproxy on|off")
            }
            let on = r.args[1] == "on"
            switch r.args[0] {
            case "cswap":
                guard model.cswap != nil || !on else { throw Fail("cswap is not installed") }
                guard model.cswapEnabled != on else { return ControlReply(ok: true, result: .object(["unchanged": .bool(true)])) }
                model.cswapEnabled = on
            case "cliproxy":
                guard model.cliproxyKeyPresent || !on else { throw Fail("store a management key first (proxy-key)") }
                guard model.cliproxyEnabled != on else { return ControlReply(ok: true, result: .object(["unchanged": .bool(true)])) }
                model.cliproxyEnabled = on
            default: throw Fail("unknown engine \(r.args[0])")
            }
            return ControlReply(ok: true, result: .object(["restarting": .bool(true)]), restarting: true)

        case "proxy":
            var out: [String: JSONValue] = [
                "baseURL": .string(model.cliproxyBaseURL),
                "keyPresent": .bool(model.cliproxyKeyPresent),
                "enabled": .bool(model.cliproxyEnabled),
            ]
            if let s = model.proxyRoutingStrategy { out["routingStrategy"] = .string(s) }
            if let e = model.engineErrors[CLIProxyEngine.engineID] { out["error"] = .string(e) }
            return ControlReply(ok: true, result: .object(out))

        case "proxy-key":
            let url = r.options["url"] ?? model.cliproxyBaseURL
            model.saveCLIProxy(baseURL: url, key: r.secret ?? "")
            return ControlReply(ok: true, result: .object(["restarting": .bool(true)]), restarting: true)

        case "proxy-routing":
            guard let strategy = r.args.first, CLIProxyEngine.routingStrategies.contains(strategy) else {
                throw Fail("usage: proxy-routing \(CLIProxyEngine.routingStrategies.joined(separator: "|"))")
            }
            guard let proxy = model.registry.engine(id: CLIProxyEngine.engineID) as? CLIProxyEngine else {
                throw Fail("the CLIProxyAPI engine is off")
            }
            try await proxy.setRoutingStrategy(strategy)
            await model.refreshSnapshot()
            return ControlReply(ok: true, result: .object(["routingStrategy": .string(strategy)]))

        default:
            return .failure("\(r.command) is in the manifest but not implemented")
        }
    }

    // MARK: payloads

    private func target(_ r: ControlRequest) throws -> (FleetState, Int) {
        guard r.args.count >= 2, let n = Int(r.args[1]) else {
            throw Fail("usage: \(r.command) <fleet> <n>")
        }
        guard let fleet = model.fleets.first(where: { $0.id == r.args[0] }) else {
            throw Fail("no fleet \(r.args[0]); fleets: \(model.fleets.map(\.id).joined(separator: ", "))")
        }
        return (fleet, n)
    }

    private struct FleetPayload: Encodable {
        let key: String, engineID: String, provider: String
        let capabilities: [String]
        let caveat: String?
        let activeNumber: Int?, nextCandidate: Int?
        let nextRecovery: NextRecovery?
        let accounts: [Account]
    }

    private func fleetPayload(_ f: FleetState) -> FleetPayload {
        FleetPayload(key: f.id, engineID: f.engineID, provider: f.provider.rawValue,
                     capabilities: Self.names(f.capabilities),
                     caveat: model.fleetCaveats[f.engineID],
                     activeNumber: f.activeNumber, nextCandidate: f.nextCandidate,
                     nextRecovery: f.nextRecovery, accounts: f.accounts)
    }

    private func fleetsPayload() -> [FleetPayload] { model.fleets.map(fleetPayload) }

    private struct EngineStatus: Encodable {
        let enabled: Bool, registered: Bool, keyPresent: Bool?
    }
    private struct Status: Encodable {
        let version: String, sha: String
        let engines: [String: EngineStatus]
        let badge: String
        let signInRunning: Bool
        let playground: Bool
        let socket: String
    }

    private func status() -> Status {
        let info = Bundle.main.infoDictionary ?? [:]
        return Status(
            version: info["CFBundleShortVersionString"] as? String ?? "dev",
            sha: info["InfinitusGitSHA"] as? String ?? "dev",
            engines: [
                "cswap": EngineStatus(enabled: model.cswapEnabled, registered: model.cswapRegistered,
                                      keyPresent: nil),
                "cliproxy": EngineStatus(enabled: model.cliproxyEnabled,
                                         registered: model.registry.engine(id: CLIProxyEngine.engineID) != nil,
                                         keyPresent: model.cliproxyKeyPresent),
            ],
            badge: model.engineBadge.map { "\($0)" } ?? "none",
            signInRunning: TokenFlow.shared.running || model.addingFirstAccount,
            playground: model.isPlayground,
            socket: ControlProtocol.socketURL().path)
    }

    static func names(_ caps: EngineCapabilities) -> [String] {
        let table: [(EngineCapabilities, String)] = [
            (.switch, "switch"), (.rotate, "rotate"), (.reorder, "reorder"), (.hold, "hold"),
            (.rename, "rename"), (.remove, "remove"), (.addCurrent, "addCurrent"),
            (.addToken, "addToken"), (.addOAuth, "addOAuth"), (.autoSwitch, "autoSwitch"),
            (.costReport, "costReport"), (.history, "history"), (.settings, "settings"),
        ]
        return table.filter { caps.contains($0.0) }.map(\.1)
    }
}
