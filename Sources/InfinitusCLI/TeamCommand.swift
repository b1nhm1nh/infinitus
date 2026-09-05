import Foundation
import InfinitusCore

// `infinitusctl team …` runs in-process — no control socket, so a Linux
// or Windows member needs only this binary (spec §9). State lives under
// TeamPaths.standard() (override: INFINITUS_TEAM_DIR); secrets in
// FileSecrets under it — the Mac app's keychain store arrives in plan 5.

func teamUsage() -> String {
    """
    usage: infinitusctl team <subcommand> [args] [--option value]

      create <name> --remote <url> [--token -]     create a team on an empty git remote (token from stdin)
      code [--days N]                              team code for joiners (default 7 days)
      request - --name <n> [--devices a,b]         ask to join; the code on stdin (argv only if it carries no credential)
      status [--team <id>]                         this machine's team(s)
      requests                                     pending join requests (leaders)
      approve <kid> | decline <kid>                answer a request (leaders)
      fetch                                        pull the store and accept the roster
      publish --kind <k> --path <p> --file <f> [--audience leaders|team|<kid,kid>]
      list                                         envelopes addressed to me
      read <path> [--out <file>]                   decrypt one envelope

    """
}

private func emit<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? enc.encode(value) { print(String(decoding: data, as: UTF8.self)) }
}

private func fail(_ message: String, code: Int32 = 1) -> Int32 {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    return code
}

private struct ReadableEntry: Encodable {
    var path: String; var size: Int; var kind: String; var from: String; var at: Int
}

func runTeam(_ args: [String]) -> Int32 {
    guard let sub = args.first, sub != "--help", sub != "-h" else {
        print(teamUsage(), terminator: "")
        return args.isEmpty ? 2 : 0
    }
    var positional: [String] = []
    var options: [String: String] = [:]
    var i = 1
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            // Every team option takes a value; a bare flag is a typo, not a
            // boolean (`read --out` must never write to a file named "true").
            let key = String(a.dropFirst(2))
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
                return fail("--\(key) needs a value\n\n\(teamUsage())", code: 2)
            }
            options[key] = args[i + 1]; i += 1
        } else {
            positional.append(a)
        }
        i += 1
    }

    // Team gate (spec §2.2): starting, joining or admitting into a team
    // needs the biometric lock on wherever a lock exists — the Mac app's
    // setting, read from its prefs domain. Linux is open until its
    // passphrase lock ships; INFINITUS_LOCK_GATE=open is the CI/dev hatch
    // (TeamGate.swift).
    if ["create", "request", "approve"].contains(sub),
       case .needsLock(let why) = TeamGate.check(lockEnabled: LockSetting.enabledOnThisMachine()) {
        return fail("\(why) (Infinitus › Settings › Lock)")
    }

    let paths = TeamPaths.standard()
    let secrets = FileSecrets(dir: paths.secretsDir)

    func client() throws -> TeamClient {
        let ids = paths.teamIDs()
        let id = options["team"] ?? (ids.count == 1 ? ids[0] : nil)
        guard let id else {
            throw NSError(domain: "team", code: 1, userInfo: [NSLocalizedDescriptionKey:
                ids.isEmpty ? "no team on this machine (create or request one)" : "several teams: pass --team <id> (\(ids.joined(separator: ", ")))"])
        }
        return try TeamClient.open(id: id, paths: paths, secrets: secrets)
    }

    do {
        switch sub {
        case "create":
            guard let name = positional.first, let remote = options["remote"] else { return fail(teamUsage(), code: 2) }
            guard options["token"] == nil || options["token"] == "-" else {
                return fail("--token takes only '-' (read from stdin)", code: 2)
            }
            var token: String?
            if options["token"] == "-" {
                token = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if token?.isEmpty == true { token = nil }
            }
            let c = try TeamClient.create(name: name, remote: remote, token: token, paths: paths, secrets: secrets)
            emit(try c.status())
        case "code":
            let days = Int(options["days"] ?? "7") ?? 7
            let c = try client(); _ = try c.fetch()
            emit(["code": try c.code(expiresIn: days * 86_400)])
        case "request":
            guard let arg = positional.first, let name = options["name"] else { return fail(teamUsage(), code: 2) }
            let code: String
            if arg == "-" {
                code = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                // The code embeds the store write credential; argv is world
                // readable. An expired code still carries a live one, so the
                // probe ignores expiry.
                if (try? TeamCode.decode(arg, now: Int.min))?.token != nil {
                    return fail("this code carries a credential: pass it on stdin (`team request -`)", code: 2)
                }
                code = arg
            }
            let devices = options["devices"]?.split(separator: ",").map(String.init) ?? []
            #if os(macOS)
            let platform = "macos"
            #elseif os(Linux)
            let platform = "linux"
            #else
            let platform = "windows"
            #endif
            let c = try TeamClient.request(code: code, name: name, devices: devices, platform: platform,
                                           paths: paths, secrets: secrets)
            emit(try c.status())
        case "status":
            if options["team"] == nil, paths.teamIDs().count > 1 {
                emit(try paths.teamIDs().map { try TeamClient.open(id: $0, paths: paths, secrets: secrets).status() })
            } else {
                emit(try client().status())
            }
        case "requests":
            let c = try client(); _ = try c.fetch()
            emit(try c.requests().map(\.doc))
        case "approve":
            guard let kid = positional.first else { return fail(teamUsage(), code: 2) }
            let c = try client(); _ = try c.fetch(); try c.approve(kid: kid); emit(try c.status())
        case "decline":
            guard let kid = positional.first else { return fail(teamUsage(), code: 2) }
            let c = try client(); _ = try c.fetch(); try c.decline(kid: kid); emit(try c.status())
        case "fetch":
            let c = try client(); _ = try c.fetch(); emit(try c.status())
        case "publish":
            guard let kind = options["kind"], let path = options["path"], let file = options["file"] else { return fail(teamUsage(), code: 2) }
            let audience: TeamRoster.ShareTarget
            switch options["audience"] ?? "leaders" {
            case "leaders": audience = .leaders
            case "team": audience = .team
            case let kids: audience = .members(kids.split(separator: ",").map(String.init))
            }
            let c = try client(); _ = try c.fetch()
            let stored = try c.publish(kind: kind, path: path, plaintext: try Data(contentsOf: URL(fileURLWithPath: file)), audience: audience)
            emit(["path": stored])
        case "list":
            let c = try client(); _ = try c.fetch()
            emit(try c.readable().map { entry -> ReadableEntry in
                let (h, _) = try c.read(entry.path)
                return ReadableEntry(path: entry.path, size: entry.size, kind: h.kind, from: h.from, at: h.at)
            })
        case "read":
            guard let path = positional.first else { return fail(teamUsage(), code: 2) }
            let c = try client(); _ = try c.fetch()
            let (_, plain) = try c.read(path)
            if let out = options["out"] { try plain.write(to: URL(fileURLWithPath: out)) }
            else { FileHandle.standardOutput.write(plain) }
        default:
            return fail("unknown team subcommand \(sub)\n\n\(teamUsage())", code: 2)
        }
        return 0
    } catch {
        return fail("\(error)")
    }
}
