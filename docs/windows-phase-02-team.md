# Phase 02 — Team on Windows: git resolver, store lanes, minimal surfaces

## Goal

Make the team store work on Windows by giving `TeamGit` a `git.exe` it
can actually run, then expose a v1 team surface: identity, join by code,
publish and read. The whole `Team/` subtree already compiles into
`infinitus-win` today and is simply never called — this phase turns one
hardcoded POSIX path into a resolver and then wires the smallest honest
UI on top.

## Non-goals

- **Nearby LAN invites are deferred**, not designed here. See "Nearby" —
  the decision is to ship v1 without mDNS browse and say so.
- No team control grantor (answering granted commands). That is phase 03
  and depends on this one.
- No new team concepts. Windows consumes the existing spec; anything
  missing goes upstream, not into a Windows-only branch.

## Current state

**The blocker is one line.**

- `Sources/InfinitusCore/Team/TeamGit.swift:398` —
  `p.executableURL = URL(fileURLWithPath: "/usr/bin/env")`, then
  `var argv = ["git"]` at `:399`. Hardcoded POSIX. It **compiles** on
  Windows and fails at runtime.
- The surrounding fences are already Windows-clean:
  `TeamGit.swift:391` fences only Apple non-mac platforms (iOS/tvOS/
  watchOS/visionOS) out of `runOnce` with `GitError.unavailable`;
  Windows falls through to the real body. SIGPIPE is already fenced —
  `:378-388` (`#elseif !os(Windows)`, and
  `#if !canImport(Darwin) && !os(Windows)` for the `ignoreSigpipe`
  static), so `TeamGit.feed` (`:377`) is safe here.
- `Sources/InfinitusCore/Team/TeamGit.swift:280` — the `drainingPool`
  entry every command goes through; `:390` `runOnce` is the only
  subprocess site, so one resolver fixes all of it.

**Everything else in Team is already portable.** Grepping the 41 files
in `Sources/InfinitusCore/Team/` finds ten fences total and no
Darwin-only import (all `Foundation`, swift-crypto, `CZlib`):

- `TeamSecrets.swift:46` — Windows branch already written (no
  `rename(2)` on NTFS; remove + move, "#171 parity").
- `TeamIdentityExport.swift:65` — Windows branch already written
  (`.withoutOverwriting` instead of `O_EXCL`, "#203").
- `DrainingPool.swift:11` — `#if canImport(ObjectiveC)`.
- `TeamNearby.swift:475` — `#if os(macOS) || os(Linux)` around
  `Client.browse`; Windows throws `ClientError.unavailable`.
- `TeamPaths.swift:17` — `#if os(macOS)` → Application Support, `#else`
  → XDG. **Windows lands in the XDG branch**:
  `$HOME/.local/share/infinitus/teams`. Functional, not idiomatic.
- `Package.swift:11-13` — `InfinitusCore` has no `sources:`/`exclude:`
  list, so the whole `Team/` subtree compiles everywhere;
  `Package.swift:88` and `:99` — both Windows products already depend on
  it. `TeamClient`, `TeamControl`, `TeamGrants` are **already linked
  into `infinitus-win`**.

**No team code in `windows/` at all** — grepping `Team` across
`windows/Sources` returns zero matches. No pane, no route, no CLI verb.

**Tests already skip on Windows for exactly this reason.**
`Tests/InfinitusCoreTests/TeamGitTests.swift:17-24` — a
`skipOffPOSIX()` helper whose comment reads "TeamGit shells out through
`/usr/bin/env git` — macOS/Linux only until Windows grows a
PATH-resolved git shim". Same skip at `TeamControlStoreTests.swift:7-10`,
`TeamClientTests.swift` (six sites: `:33`, `:51`, `:85`, `:178`, `:210`,
`:254`), `TeamPublisherTests.swift:15`, `TeamReaderTests.swift:15`,
`TeamMembershipTests.swift:15`, `TeamInvitesTests.swift:6`,
`TeamAggregatesTests.swift:14`, `TeamNearbyTests.swift:15`,
`TeamSecretsTests.swift:6` and `:59`. The test helpers themselves also
shell `/usr/bin/env git` — `TeamGitTests.swift:29-31` (`makeRemote`).

**A git resolver already exists in the wrong place.**
`windows/Sources/InfinitusWinUI/WinRepoStatsScanner.swift:54-73`
(`findGit()`) tries four literal install paths — `C:\Program
Files\Git\cmd\git.exe`, `...\bin\git.exe`, `Program Files (x86)`, and a
hardcoded `C:\Users\BM\AppData\Local\Programs\Git\cmd\git.exe` — then
walks `Path`/`PATH` for `git.exe`. It is private to that scanner and one
candidate is a personal path.

## Design

### Step 1 — the resolver (core)

**`Sources/InfinitusCore/Team/TeamGit.swift`** — fence `runOnce`'s
executable selection. On POSIX, keep `/usr/bin/env` + `["git"]` exactly
as today (it is what every green test exercises). On Windows, resolve a
`git.exe` and pass the args directly, with no `env` prefix.

Put the resolution in a `GitLocator` beside `TeamGit`, shaped like
`CswapLocator` (`Engines/Cswap/CswapCLI.swift:5-27`) since that is the
house pattern for "find a tool": a `defaultCandidates(home:)`, a
`locate(candidates:exists:)`, and an `INFINITUS_GIT` env override for
tests and odd installs. Candidates, in order: `PATH` (Git for Windows
puts `git.exe` there; this is the common case), then
`%ProgramFiles%\Git\cmd\git.exe`, `%ProgramFiles%\Git\bin\git.exe`,
`%ProgramFiles(x86)%\Git\cmd\git.exe`, then
`%LOCALAPPDATA%\Programs\Git\cmd\git.exe` (the per-user install — this
is what the personal path in `WinRepoStatsScanner` actually was, so
derive it from the environment, never hardcode a username). Read the
program-files roots from the environment rather than literals so a
non-C: install works.

Resolve **once, lazily, cached** — `runOnce` is called per git command
and a PATH walk per command is waste. Cache the miss too, so a box
without git does not re-walk on every publish.

No git → throw. Prefer a distinct `GitError` case ("git not found") over
`unavailable`, so the CLI and the pane can say "install Git for
Windows" rather than "team is unavailable here", which would be a lie
once git is installed.

Leave `WinRepoStatsScanner.findGit()` **alone** in this phase. It is a
different target (`InfinitusWinUI`) doing a different job (repo stats),
and folding it in means editing a file phase 06 may also touch. Note it
as follow-up: once `GitLocator` is in core, that private copy should
call it and drop the hardcoded username.

**`credential.helper`.** `runOnce` injects a helper as a shell function
when a token is present — `TeamGit.swift:401-403`,
`!f() { echo username=...; }; f`. That is `sh` syntax; Git for Windows
ships bash, and git runs credential helpers through its own shell, so it
is expected to work — **but it must be probed, not assumed**. It is the
one part of this design with real risk (see Risks). Probe it against a
token-bearing remote early; if it fails, the fallback is
`GIT_ASKPASS`/`credential.helper=store` semantics, and the token still
must not reach argv (CLAUDE.md: secrets over stdin, never argv — note
the token already travels by environment via `Self.tokenEnv`, which the
helper reads, and that stays true).

### Step 2 — store lanes green

With the resolver in, the store lanes (`TeamClient.fetch()` at
`Sources/InfinitusCore/Team/TeamClient.swift:199`, publish, read) need
no code change — they are pure git-over-`runOnce`. The work is turning
the skips into coverage (see Test plan) and fixing whatever real Windows
path behaviour surfaces: NTFS path separators inside the store, and
`TeamPaths` (below).

**`TeamPaths.swift:17-25`** — add a Windows branch. XDG under `$HOME` is
wrong here; the rest of the Windows app uses `%APPDATA%`/`%LOCALAPPDATA%`
(`windows/README.md:498-500` for the pair token,
`Package.swift`-adjacent conventions elsewhere). Team state is roaming
user data, not cache, so `%APPDATA%\Infinitus\teams`. `INFINITUS_TEAM_DIR`
already overrides (`:14-16`), which is what tests and a second instance
use. This is a **migration-free** change only if no Windows box has a
team store yet — nothing calls team on Windows today, so it is safe to
pick the right path now rather than migrate later.

### Step 3 — the v1 surfaces

Minimal and honest. Two surfaces, no third.

**The CLI first: `infinitusctl team`.** It already exists and is built
on every platform — `Sources/InfinitusCLI/main.swift:13`
(`args.first == "team"`), `TeamCommand.swift:11` (usage: create, code,
request, approve, publish…), `TeamControlCommand.swift`,
`TeamNearbyCommand.swift`. CLAUDE.md's comment at
`Package.swift:22-24` says `infinitusctl team …` runs in-process on
every platform precisely so this works. So **v1 team on Windows is
mostly the CLI already working** once git resolves. That is the cheapest
real surface and it should be the phase's first acceptance line.

**Then one tray pane: "Team".** Identity (kid, name, devices), the
team list, join-by-code, publish state, and the roster read. Model it on
the Mac's team pane for wording and on the existing Windows pane
pattern — a `PaneDescriptor` with `section:` and `keywords:`
(`windows/Sources/InfinitusTrayWin/Panes/CswapPane.swift:8-18` is the
template), owner-drawn controls via `PaneControls`, and background work
through `ctx.async(_:then:)` (`CswapPane.swift:325-341`) so the git
shellout never blocks the message loop. New file:
`windows/Sources/InfinitusTrayWin/Panes/TeamPane.swift`, registered in
the catalog alongside the others.

Publish must be **off the UI thread and throttled**. The Mac runs the
pass on a 300 s interval and only inside a `refreshIfStale` guard
(`Sources/Infinitus/TeamModel.swift:21`, `:245`). A pane that fetched on
every repaint would be both slow and a CLAUDE.md perf violation. v1:
fetch on pane open and on an explicit button, nothing periodic — the
periodic loop arrives with phase 03, which needs it anyway.

**No daemon team routes in v1.** The daemon's HTTP surface is the
phone's contract (`MirrorTransport`); adding team routes there is a
wire-format change the phone does not ask for. Team on the daemon is
phase 03's grantor pass, which is a git fetch loop, not a route.

### Nearby: deferred, with the reason

`TeamNearby.Client.browse` is fenced `#if os(macOS) || os(Linux)`
(`TeamNearby.swift:474-487`) because `MDNS`'s sockets are —
`Sources/InfinitusCore/MDNS.swift:430` opens the platform fence, and
`:448` `Socket`, `:532` `Advertiser`, `:578` `browse` all live inside
it. Windows throws `ClientError.unavailable`.

What Windows *does* have is **advertise-only**:
`windows/Sources/InfinitusWin/WinBonjour.swift:8` uses
`DnsServiceRegister` (windns.h) — `:68-105` constructs an instance and
registers it. That is one-way. `DnsServiceBrowse` exists as an API, but
`WinBonjour` does not use it, and — the deciding detail —
`DnsServiceConstructInstance` is called with `nil` for the TXT key/value
arrays (`WinBonjour.swift:68-79`, the two `nil`s before the trailing
pair). **Nearby's whole handshake is TXT-borne**:
`NearbyRecord(txtStrings:)` is what carries `name`, `kid`, `team`,
`role`, `discoverable` (`TeamNearby.swift:476-482`), and the joiner
refuses a peer that is not `role == "leader"` with a `team` and `kid`
(`:490`). So carrying nearby on the current Windows stack needs both a
browse path and TXT records, i.e. real work in `WinBonjour` — not a
fence flip.

The cheap middle path exists and should be noted rather than built:
`MDNS.swift:1-429` is a **portable wire codec** (`DNSName`, `Question`,
`Record`, `Message`, `Collector`, `Responder` — all outside the
platform fence at `:430`). A Windows `MDNS.Socket` over Winsock
multicast would reuse the entire codec. That is a phase of its own.

**v1 decision:** join by **code**, not by nearby. `TeamCode.swift`
exists and `infinitusctl team code`/`request`/`approve` already
implement it, and it is transport-free. The Team pane says LAN discovery
is macOS/Linux-only and points at the code flow. This keeps the phase S/M
instead of L and does not lie to the user.

## Test plan

- `swift build --product infinitus-win`, then `--product
  infinitus-tray-win` (one per invocation). `swift test` under
  `. .\windows\env.ps1`; never set `INCLUDE`/`LIB` there
  (`windows/env.ps1:9-12`). zlib is the vendored `CZlib`
  (`Package.swift:44-45`) — the team envelope deflates through it, and
  the manifest comment at `:37-43` promises deterministic output, so a
  **cross-platform envelope round-trip is a real test worth adding**:
  seal on Windows, verify the bytes match the macOS fixture.
- **The skip removals are the deliverable.** Each of these currently
  early-exits on Windows; with a resolver they should run for real:
  `TeamGitTests.swift:17-24` (`skipOffPOSIX`, plus `makeRemote` at
  `:27-31` which itself shells `/usr/bin/env git` — the helper needs the
  same resolver), `TeamClientTests.swift:33/51/85/178/210/254`,
  `TeamPublisherTests.swift:15`, `TeamReaderTests.swift:15`,
  `TeamMembershipTests.swift:15`, `TeamInvitesTests.swift:6`,
  `TeamAggregatesTests.swift:14`, `TeamControlStoreTests.swift:7`.
  Convert them from `XCTSkipIf(true, …)` to a skip conditioned on
  **git not being installed** — the honest gate, and it keeps CI on a
  git-less runner green.
- **Stays skipped, correctly:** `TeamNearbyTests.swift:15` — nearby is
  deferred by design, so its skip reason should be rewritten from
  "not ported" to "LAN discovery is macOS/Linux-only (see phase 02)".
  `TeamSecretsTests.swift:6`/`:59` — check whether these are git skips
  or POSIX-permission skips (`TeamSecrets` already has a Windows branch
  at `:46`, so the 0600 assertions may be the real reason and must stay).
- Real coverage, new: `GitLocator` candidate-ordering tests with an
  injected `exists:` closure (platform-independent, like the cswap
  locator's); `TeamPaths.standard` returning `%APPDATA%\Infinitus\teams`
  on Windows and the unchanged macOS/XDG answers elsewhere.
- Manual, on the box: `infinitusctl team create`, `code`, `publish`,
  then a `fetch` against a real remote — including a **token-bearing**
  remote, which is the credential-helper probe.

## Acceptance criteria

- [ ] `TeamGit` runs `git.exe` on Windows; the POSIX path is byte-identical
      to today and macOS/Linux tests are unchanged.
- [ ] `GitLocator` finds git off `PATH` and off both Program Files and
      per-user install roots, with no hardcoded username anywhere.
- [ ] No git installed → a distinct "git not found" error whose text
      names Git for Windows, not "team unavailable".
- [ ] `TeamPaths.standard()` on Windows is `%APPDATA%\Infinitus\teams`;
      `INFINITUS_TEAM_DIR` still overrides.
- [ ] `infinitusctl team create / code / request / approve / publish`
      all work on the box against a real remote.
- [ ] A team envelope sealed on Windows is byte-identical to the macOS
      fixture (vendored zlib determinism holds).
- [ ] The git-dependent Team suites run for real on a box with git, and
      skip on the *absence of git* rather than on `os(Windows)`.
- [ ] A token-bearing remote authenticates (credential helper works) or
      the phase records the fallback it needed.
- [ ] The Team pane shows identity, teams, join-by-code and publish
      state; it says LAN nearby is macOS/Linux-only.
- [ ] No periodic fetch is added, so idle CPU with the panel open is
      unchanged.

## Parallelization notes

**Owns exclusively:** `Sources/InfinitusCore/Team/TeamGit.swift`,
`Sources/InfinitusCore/Team/TeamPaths.swift`, the new core
`GitLocator`, every `Tests/InfinitusCoreTests/Team*Tests.swift`, and the
new `windows/Sources/InfinitusTrayWin/Panes/TeamPane.swift`.

**Safe beside:** phases 01, 04, 05, 07. Phase 01 is confined to
`CswapCLI.swift`; 04 to daemon push code; 05 to pty/ConPTY; 07 to a new
effects host.

**Collides with:** **phase 06** — both register a pane in the tray
catalog (`windows/Sources/InfinitusWinUI/SettingsCatalogWin.swift` and
the shell's registration list). Two implementers editing the same
registration list will conflict. Resolution: phase 06 owns the catalog
file; this phase reports the one registration line for 06 (or the merge)
to add, and ships `TeamPane.swift` self-contained. Also note phase 06
may spec a Team pane from the Mac's pane list — the two must not both
build one; **this phase owns Team pane, phase 06 must exclude it.**

**Blocks:** phase 03 entirely.

## Risks + open questions

- **The credential helper is the real risk.** `!f() { … }; f`
  (`TeamGit.swift:401-403`) is shell syntax evaluated by git's own
  shell. Git for Windows ships one, so it is expected to work, but a
  failure here breaks authenticated fetch/publish, which is most of
  team. Probe it in the first hour, not at the end.
- Long paths: the team store nests `<base>/<team-id>/store/…` and NTFS
  has a 260-char legacy limit. `%APPDATA%` plus a UUID team id plus
  store paths could approach it on a deep profile. Worth measuring.
- Line endings: git on Windows may apply `core.autocrlf` to store files,
  which would change bytes under a signature. **Check whether the store
  needs `core.autocrlf=false` / a `.gitattributes`** — a silent CRLF
  rewrite would break envelope verification, and it would look like a
  crypto bug.
- File locking: NTFS holds locks where POSIX does not; a concurrent
  fetch and read could fail where the Mac's does not. The
  `drainingPool` (`TeamGit.swift:280`) serializes commands, which likely
  covers it.
- Open: does the Mac's team pane have Windows-inapplicable controls
  (nearby, keychain-backed identity) that the pane must omit rather than
  grey out?
- Open: `TeamSecretsTests.swift:6`/`:59` skip reasons — git or POSIX
  modes? Determines whether they can be un-skipped here.

## Estimated size

**M.** The resolver is S; the skip conversion plus real Windows path,
CRLF and credential-helper behaviour is where the time goes. The pane
adds most of the rest. Splitting it (resolver + CLI as one, pane as a
follow-up) is reasonable if it runs long.
