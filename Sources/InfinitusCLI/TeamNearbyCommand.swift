import Foundation
import InfinitusCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Glibc)
import Glibc
#endif

// `infinitusctl team nearby | request --nearby <kid> | --discoverable`
// (spec §6.4, §9 "Linux/Windows discovery"): the mDNS browser and
// responder from MDNS.swift, the two LAN routes over PosixHTTPServer.
// Its own file so TeamCommand.swift (the publisher's) carries only the
// dispatch line at the top of `runTeam`.

func teamNearbyUsage() -> String {
    """
    usage: infinitusctl team nearby [--seconds N]
               list Infinitus machines on this network (default 3 s)
           infinitusctl team request --nearby <kid> --name <n> [--devices a,b] [--seconds N]
               send a join request to that leader over the LAN — no code to paste
           infinitusctl team --discoverable [--name <n>] [--port N]
               advertise this machine and answer /team/key + /team/request until Ctrl-C (Linux;
               on the Mac the app advertises: `infinitusctl team-discoverable on`).
               Binds every interface: run it on a LAN you trust, never on a box with a public address.

    """
}

#if os(macOS)
private let nearbyPlatform = "macos"
#elseif os(Linux)
private let nearbyPlatform = "linux"
#else
private let nearbyPlatform = "windows"
#endif

private func emit<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? enc.encode(value) { print(String(decoding: data, as: UTF8.self)) }
}

private func fail(_ message: String, code: Int32 = 1) -> Int32 {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    return code
}

/// nil when `args` is not a nearby command — `runTeam` carries on.
func runTeamNearby(_ args: [String]) -> Int32? {
    guard let sub = args.first else { return nil }
    let mine = sub == "nearby" || sub == "--discoverable" || (sub == "request" && args.contains("--nearby"))
    guard mine else { return nil }
    if args.contains("--help") || args.contains("-h") {
        print(teamNearbyUsage(), terminator: "")
        return 0
    }
    // Every option takes a value; a bare flag is a typo (same rule as `runTeam`).
    var options: [String: String] = [:]
    var i = 1
    while i < args.count {
        let a = args[i]
        guard a.hasPrefix("--") else { return fail(teamNearbyUsage(), code: 2) }
        let key = String(a.dropFirst(2))
        guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
            return fail("--\(key) needs a value\n\n\(teamNearbyUsage())", code: 2)
        }
        options[key] = args[i + 1]
        i += 2
    }
    let paths = TeamPaths.standard()
    let secrets = FileSecrets(dir: paths.secretsDir)
    let seconds = Double(options["seconds"] ?? "3") ?? 3
    do {
        switch sub {
        case "nearby":
            emit(try TeamNearby.Client.browse(seconds: seconds))
        case "request":
            guard let kid = options["nearby"], let name = options["name"] else { return fail(teamNearbyUsage(), code: 2) }
            guard let peer = try TeamNearby.Client.browse(seconds: seconds).first(where: { $0.kid == kid && $0.discoverable }) else {
                return fail("no discoverable machine with kid \(kid) answered within \(Int(seconds))s")
            }
            let devices = options["devices"]?.split(separator: ",").map(String.init) ?? []
            do {
                let out = try TeamNearby.Client.request(to: peer, name: name, devices: devices, platform: nearbyPlatform,
                                                        paths: paths, secrets: secrets,
                                                        http: { m, h, p, path, body in try http(m, host: h, port: p, path: path, body: body) })
                emit(["team": out.team, "leader": out.leader, "kid": out.kid, "stored": out.stored])
            } catch TeamNearby.Client.ClientError.notALeader {
                return fail("\(peer.name) leads no team")
            } catch TeamNearby.Client.ClientError.keyMismatch(let s) {
                return fail("\(peer.name) is not answering \(TeamNearby.keyPath) (\(s))")
            } catch TeamNearby.Client.ClientError.refused(let s) {
                return fail("\(peer.name) refused the request (\(s))")
            }
        case "--discoverable":
            return runDiscoverable(name: options["name"], port: UInt16(options["port"] ?? "0") ?? 0,
                                   paths: paths, secrets: secrets)
        default:
            return nil
        }
        return 0
    } catch {
        return fail("\(error)")
    }
}

/// One blocking HTTP exchange with a peer; the CLI has no event loop to
/// hand a completion to.
private func http(_ method: String, host: String, port: UInt16, path: String, body: Data? = nil) throws -> (Int, Data) {
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
    var result: (Int, Data) = (0, Data())
    var failure: Error?
    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error { failure = error }
        else { result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()) }
        done.signal()
    }.resume()
    done.wait()
    if let failure { throw failure }
    return result
}

/// Set from the signal handler; read by the main thread's wait loop.
private var discoverableStopRequested = false

private func runDiscoverable(name: String?, port: UInt16, paths: TeamPaths, secrets: TeamSecrets) -> Int32 {
    #if canImport(Glibc)
    let machine = name ?? ProcessInfo.processInfo.hostName
    let local = TeamNearby.Local.load(name: machine, discoverable: true, paths: paths, secrets: secrets)
    let endpoint = TeamNearby.Endpoint(local: local,
                                       store: { try TeamNearby.Store.save($0, paths: paths, secrets: secrets) },
                                       storeInvite: { try TeamNearby.Store.saveInvite($0, paths: paths) })
    let server = PosixHTTPServer { request in
        TeamNearby.respond(request, endpoint: endpoint) ?? MirrorTransport.notFoundResponse()
    }
    do {
        let bound = try server.start(port: port)
        let ipv4 = PosixInterfaceAddresses.ipv4().first ?? "127.0.0.1"
        let service = MDNS.Service(instance: machine, host: MDNS.hostLabel(machine), port: bound,
                                   txt: local.record.txtStrings, ipv4: ipv4)
        let advertiser = try MDNS.Advertiser(service: service)
        try advertiser.start()
        FileHandle.standardError.write(Data(
            "discoverable as \(machine) (kid \(local.record.kid), \(local.record.role)) on \(ipv4):\(bound) — Ctrl-C to stop\n".utf8))
        // Ctrl-C sends the goodbye first: a bare SIGINT death would leave
        // a stale PTR in every browser's cache for 75 minutes. A
        // non-capturing C handler flips a flag (SIG_IGN is a macro cast
        // Glibc doesn't import; libdispatch signal sources are Darwin-shaped).
        signal(SIGINT) { _ in discoverableStopRequested = true }
        signal(SIGTERM) { _ in discoverableStopRequested = true }
        while !discoverableStopRequested { Thread.sleep(forTimeInterval: 0.25) }
        advertiser.stop()
        server.stop()
        return 0
    } catch {
        return fail("\(error)")
    }
    #else
    return fail("`team --discoverable` serves on Linux; on the Mac the Infinitus app advertises — `infinitusctl team-discoverable on`",
                code: 2)
    #endif
}
