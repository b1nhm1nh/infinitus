// infinitus-win — the Windows mirror daemon (docs/plan-windows/01-stack.md).
// W3: `sessions`, W5: `pair`. W4 (HTTP listener) and W7 (`serve`) come
// next, on top of InfinitusCore's feed, pairing and snapshot code.
import Foundation
import InfinitusCore
#if os(Windows)
import CRT   // exit(3): Foundation doesn't re-export it on Windows
#endif

/// Tracks the app release (VERSION); W17 bumps it with the docs.
let infinitusWinVersion = "0.4.1"

/// The Mac's mirror port, so a QR from either host scans the same.
let defaultMirrorPort: UInt16 = 47824

/// Subcommand dispatch — W4/W6/W7 add their entries here, bodies below.
let commands: [String: ([String]) -> Int32] = [
    "sessions": sessions,
    "pair": pair,
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let subcommand = CommandLine.arguments.dropFirst().first
if subcommand == "--version" || subcommand == "-V" {
    print("infinitus-win \(infinitusWinVersion)")
    exit(0)
}
guard let subcommand, let run = commands[subcommand] else {
    print("infinitus-win \(infinitusWinVersion) — Infinitus mirror daemon for Windows")
    let seen = subcommand.map { " \($0)" } ?? ""
    print("unknown or missing subcommand\(seen) — one of \(commands.keys.sorted().joined(separator: ", "))")
    exit(2)
}
exit(run(Array(CommandLine.arguments.dropFirst(2))))

// MARK: - sessions (W3)

/// `infinitus-win sessions` — every live Claude Code session on this box
/// as JSON: pid, name, kind, status, cwd, messagingSocketPath, and both
/// liveness signals (alive = process + FILETIME match, pipe = a server is
/// listening on the messaging pipe).
func sessions(_ args: [String]) -> Int32 {
    let rows = WinSessions.list(claudeDir: ClaudeSessions.configHome())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(rows) else { fail("sessions: couldn't encode") }
    print(String(data: data, encoding: .utf8) ?? "[]")
    return 0
}

// MARK: - pair (W5)

/// `infinitus-win pair [--show] [--rotate] [--token-file P] [--stdin]
/// [--port N]` — print the `infinitus://pair?…` URL the phone pairs from
/// (one endpoint per route: LAN, then tailnet), with a QR when qrencode
/// is on PATH. The token lives in `%APPDATA%\Infinitus\pair-token`.
func pair(_ args: [String]) -> Int32 {
    var show = false, rotate = false, fromStdin = false
    var tokenFile: String?, port: UInt16 = defaultMirrorPort
    var index = args.startIndex
    while index < args.endIndex {
        switch args[index] {
        case "--show": show = true
        case "--rotate": rotate = true
        case "--stdin": fromStdin = true
        case "--token-file":
            index += 1
            guard index < args.endIndex else { fail("pair: --token-file needs a path") }
            tokenFile = args[index]
        case "--port":
            index += 1
            guard index < args.endIndex, let parsed = UInt16(args[index]) else {
                fail("pair: --port needs a number")
            }
            port = parsed
        default:
            fail("pair: unknown flag \(args[index])")
        }
        index += 1
    }

    let token: String
    do {
        if let tokenFile {
            let normalized = MirrorPairing.normalize(
                (try? String(contentsOfFile: tokenFile, encoding: .utf8)) ?? "")
            guard !normalized.isEmpty else { fail("pair: \(tokenFile) holds no token") }
            try WinPairingStore.store(normalized)
            token = normalized
        } else if fromStdin {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let normalized = MirrorPairing.normalize(String(data: data, encoding: .utf8) ?? "")
            guard !normalized.isEmpty else { fail("pair: stdin held no token") }
            try WinPairingStore.store(normalized)
            token = normalized
        } else if rotate {
            token = MirrorPairing.generateToken()
            try WinPairingStore.store(token)
        } else {
            token = try WinPairingStore.loadOrCreate()
        }
    } catch {
        fail("pair: \(error)")
    }
    if show {
        print(token)
        return 0
    }

    let addresses = WinAddresses.ipv4()
    var endpoints: [String] = []
    if let lan = MirrorPairing.lanAddress(in: addresses) {
        endpoints.append("http://\(lan):\(port)")
    }
    if let tailnet = MirrorPairing.tailnetAddress(in: addresses) {
        endpoints.append("http://\(tailnet):\(port)")
    }
    guard !endpoints.isEmpty else {
        fail("pair: no non-loopback IPv4 address found — connect to a network first")
    }
    let url = MirrorPairing.pairURL(endpoints: endpoints, token: token)
    print(url)
    print("pairing token \(MirrorPairing.mask(token)) — `infinitus-win pair --show` prints it")
    if let qrencode = which("qrencode") {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: qrencode)
        process.arguments = ["-t", "ANSIUTF8", url]
        if (try? process.run()) != nil { process.waitUntilExit() }
    } else {
        print("install qrencode for a QR")
    }
    return 0
}

/// PATH lookup for an optional external tool (qrencode) — no shell, no
/// `where` subprocess. Windows splits on `;`; executables end in .exe.
func which(_ name: String) -> String? {
    let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
    for dir in path.split(separator: ";") where !dir.isEmpty {
        for suffix in [".exe", ".cmd", ""] {
            let candidate = "\(dir)\\\(name)\(suffix)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
    }
    return nil
}
