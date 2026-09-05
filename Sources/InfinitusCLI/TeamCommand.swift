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
      remove <kid> | promote <kid>                 roster edits (leaders; the founder cannot be removed)
      fetch                                        pull the store and accept the roster
      members                                      the roster with what each member shares to me and when
      member <kid> [--period day|week|month|year]  one member's Stats summary (default week)
      share <kind> leaders|team|<kid>[,<kid>…]     audience for stats|now|sessions|transcripts|crashes (new envelopes; see reshare)
      exclude <project-dir> [--off]                keep a Claude Code project private (local, never sent)
      publish [--projects <dir>] [--days N]        publish stats, now, sessions, redacted transcripts, crashes (default 30 days)
      reshare [--days N]                           re-wrap the last N days (default 30) to the current audiences
      put --kind <k> --path <p> --file <f> [--audience leaders|team|<kid,kid>]   one opaque file (debugging)
      list                                         envelopes addressed to me
      read <path> [--out <file>]                   decrypt one envelope

    Narrowing an audience cannot recall ciphertext teammates already fetched.

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

private struct MemberRow: Encodable {
    var kid: String; var name: String; var role: String; var lastPublished: Int?
    var shares: [String]; var sessionsNow: Int; var blockers: [String]; var crashes: Int
}

func runTeam(_ args: [String]) -> Int32 {
    if let code = runTeamNearby(args) { return code }   // nearby | --discoverable | request --nearby (TeamNearbyCommand.swift)
    guard let sub = args.first, sub != "--help", sub != "-h" else {
        print(teamUsage(), terminator: "")
        return args.isEmpty ? 2 : 0
    }
    var positional: [String] = []
    var options: [String: String] = [:]
    let bareFlags: Set<String> = ["off"]
    var flags: Set<String> = []
    var i = 1
    while i < args.count {
        let a = args[i]
        if a.hasPrefix("--") {
            let key = String(a.dropFirst(2))
            if bareFlags.contains(key) { flags.insert(key); i += 1; continue }
            // Every other team option takes a value; a bare flag is a typo,
            // not a boolean (`read --out` must never write to a file named "true").
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else {
                return fail("--\(key) needs a value\n\n\(teamUsage())", code: 2)
            }
            options[key] = args[i + 1]; i += 1
        } else {
            positional.append(a)
        }
        i += 1
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
        case "put":
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
        case "remove":
            guard let kid = positional.first else { return fail(teamUsage(), code: 2) }
            let c = try client(); _ = try c.fetch(); try c.remove(kid: kid); emit(try c.status())
        case "promote":
            guard let kid = positional.first else { return fail(teamUsage(), code: 2) }
            let c = try client(); _ = try c.fetch(); try c.promote(kid: kid); emit(try c.status())
        case "share":
            guard positional.count >= 2 else { return fail(teamUsage(), code: 2) }
            let kind = positional[0]
            guard TeamKinds.memberKinds.contains(kind) else {
                return fail("kind must be one of \(TeamKinds.memberKinds.joined(separator: ", "))", code: 2)
            }
            guard let target = TeamShares.parseTarget(Array(positional.dropFirst())) else { return fail(teamUsage(), code: 2) }
            let c = try client()
            if case .members(let kids) = target {
                // Named kids are checked against the roster as it is now, not the cached one.
                _ = try c.fetch()
                let known = Set(c.roster?.doc.everyone.map(\.keys.kid) ?? [])
                for kid in kids where !known.contains(kid) {
                    return fail("unknown kid \(kid)", code: 2)
                }
            }
            let teamDir = paths.teamDir(c.config.id)
            var shares = TeamShares.load(teamDir: teamDir)
            shares.byKind[kind] = target
            try shares.save(teamDir: teamDir)
            emit(shares)
        case "exclude":
            guard let raw = positional.first else { return fail(teamUsage(), code: 2) }
            let project = URL(fileURLWithPath: raw).standardizedFileURL.path
            var exclusions = TeamExclusions.load(paths: paths)
            exclusions.set(project, excluded: !flags.contains("off"))
            try exclusions.save(paths: paths)
            emit(exclusions)
        case "members":
            let c = try client(); _ = try c.fetch()
            let reader = try TeamReader.load(client: c)
            emit(reader.members.values.sorted { $0.name == $1.name ? $0.kid < $1.kid : $0.name < $1.name }.map { m in
                MemberRow(kid: m.kid, name: m.name, role: m.role, lastPublished: m.lastPublished,
                          shares: m.kinds.sorted(), sessionsNow: m.now?.sessions.count ?? 0,
                          blockers: m.now?.blockers ?? [], crashes: m.crashes.count)
            })
        case "member":
            guard let kid = positional.first else { return fail(teamUsage(), code: 2) }
            guard let period = Stats.Period(rawValue: options["period"] ?? "week") else {
                return fail("--period is day, week, month or year", code: 2)
            }
            let c = try client(); _ = try c.fetch()
            guard let summary = try TeamReader.load(client: c).summary(kid: kid, period: period) else {
                return fail("nothing readable from \(kid)")
            }
            emit(summary.compacted())
        case "publish":
            let c = try client(); _ = try c.fetch()
            let claudeDir = ClaudeSessions.configHome()
            var sources = TeamPublisher.Sources(
                projectsDir: options["projects"].map { URL(fileURLWithPath: $0) } ?? claudeDir.appendingPathComponent("projects"),
                home: NSHomeDirectory())
            // `--projects` only swaps the Claude Code projects dir and skips the
            // Codex scan; live sessions, the scan cache and crashes still come
            // from this machine regardless.
            sources.codexDir = options["projects"] == nil ? StatsScanner.defaultCodexDir() : nil
            sources.cacheURL = paths.teamDir(c.config.id).appendingPathComponent("scan-cache.json")
            sources.liveSessions = ClaudeSessions.list(claudeDir: claudeDir)
            sources.crashes = CrashStore(directory: CrashStore.defaultDirectory()).list()
            if let days = options["days"].flatMap(Int.init) { sources.historyDays = days }
            emit(try TeamPublisher(client: c, paths: paths).publish(sources: sources))
        case "reshare":
            let c = try client(); _ = try c.fetch()
            let days = options["days"].flatMap(Int.init) ?? 30
            emit(try TeamPublisher(client: c, paths: paths).reshare(days: days))
        default:
            return fail("unknown team subcommand \(sub)\n\n\(teamUsage())", code: 2)
        }
        return 0
    } catch {
        return fail("\(error)")
    }
}
