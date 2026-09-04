// infinitus-win — the Windows mirror daemon (docs/plan-windows/README.md).
// W2: identity only. W3 adds `sessions`, W5 `pair`, W7 `serve` on top of
// InfinitusCore's feed, pairing and snapshot code.
import InfinitusCore
#if os(Windows)
import CRT   // exit(3): Foundation doesn't re-export it on Windows
#endif

/// Tracks the app release (VERSION); W17 bumps it with the docs.
let infinitusWinVersion = "0.4.1"

let subcommand = CommandLine.arguments.dropFirst().first
if subcommand == "--version" || subcommand == "-V" {
    print("infinitus-win \(infinitusWinVersion)")
    exit(0)
}
print("infinitus-win \(infinitusWinVersion) — Infinitus mirror daemon for Windows")
print("unknown or missing subcommand: W3 adds `sessions`, W5 `pair`, W7 `serve`")
exit(2)
