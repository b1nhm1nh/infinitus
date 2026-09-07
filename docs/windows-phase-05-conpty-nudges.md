# Phase 05 — ConPTY: send-keys and nudges for daemon-spawned sessions

## Goal

Unlock key presses and pty nudges on Windows by having the daemon spawn
Claude Code under a **ConPTY it owns**, then conform that host to the
existing `PtyHost` protocol. This is opt-in and forward-looking only:
sessions already started from Windows Terminal stay unreachable, and
`keys: false` remains the truthful answer for them.

## Non-goals

- **No reach into existing terminal-spawned sessions.** Windows Terminal
  exposes no send-keys and no screen read; that is why the port shipped
  `keys: false`. Nothing here changes it for a session the daemon did
  not start.
- No screen scraping of another process's console.
- Not a replacement for the pipe lane. Pipe delivery stays first and
  preferred; ConPTY is the fallback that today does not exist.
- Optional. If phases 01-04 and 06 are the roadmap, this is the one that
  can be dropped without leaving a hole.

## Current state

### The protocol a ConPTY host must satisfy

`Sources/InfinitusCore/PtyHosts.swift:27-34` — the whole contract:

```
protocol PtyHost: Sendable {
    var name: String { get }
    func surfaces() throws -> [PtySurface]
    func sendLine(_ ref: String, _ text: String) throws   // types + Enter
    func sendEsc(_ ref: String) throws
    func readScreen(_ ref: String, lines: Int) throws -> String
}
```

All blocking, run off-main. `:7-19` `PtySurface { ref, tty?, title, pids }`;
`:23` `CommandRunner` (the injectable test seam); `:41-70`
`Subprocess.run/find` (`:67-69` never searches PATH); `:73-103`
`ProcessFacts` — **hard POSIX**: shells `/bin/ps` (`:75`) and reads
`/dev/<tty>` mtime (`:99`); `:113-125` `surface(for:tty:ancestors:name:)`
matching by tty, then pid lineage, then title. Three impls: `CmuxHost`
`:130-185`, `TmuxHost` `:189-229`, `HerdrHost` `:233-286`;
`PtyHosts.available()` `:288-297`.

**Crucially the fence is `#if !os(iOS)`** (`PtyHosts.swift:3`, closed
`:298`; same at `PtyNudge.swift:3`/`:202` and
`SessionInput.swift:323`) — **not** `os(macOS)`. So the entire pty stack
already compiles on Windows and is neutralized by *injecting an empty
host array*, not by conditional compilation. `Subprocess`/`ProcessFacts`
would fail at runtime on `/bin/ps`, but are never called because
`hosts` is empty. **A ConPTY conformance therefore needs no fence
changes** — only a Windows `available()` and real `ttyOfPid`/`ancestorsOf`.

### What PtyNudge does with a host

`Sources/InfinitusCore/PtyNudge.swift:20-31` — `Status`: `.delivered`,
`.typedUnverified`, `.capturedInput`, `.running`, `.noSurface`.
`:55-75` `nudge(...)`: locate surface → `readScreen` → running? bail →
menu? one Esc, re-read → `sendLine` → verify by echo (state machine
documented `:51-54`). `:85-101` `press(...)`: single key — `enter` =
empty `sendLine`, `esc` = `sendEsc`, else a typed line; `:78-84`
explains why it must not reuse `nudge`. `:12-18` the screen markers
(`Wait for limit to reset`, `esc to interrupt`, …), `settle = 1.0`,
`screenLines = 40`. `:128-200` `rearmRemoteControl` sweeps `/rc`.

**`readScreen` is the hard requirement.** The nudge state machine is
not "type text"; it reads the screen to decide whether the session is
already running, whether a menu is open, and whether the text echoed.
A ConPTY host that cannot render its screen buffer to text cannot
implement `PtyHost` usefully.

### Where Windows says no today

- **`windows/Sources/InfinitusWin/Routes.swift:86`** —
  `canMessage: canMessage, keys: false,` on every tail response; the
  rationale at `:76-80` — "the phone gates its composer on these.
  `keys` is false — Windows Terminal exposes no send-keys."
- `Routes.swift:9-13` — the file-header contract: "`hosts: []` keeps
  `SessionInput.deliver`'s terminal fallback out of reach… A `key` press
  on a session nobody owns therefore reports `noSurface` rather than
  pretending."
- All three `hosts: []` sites:
  `windows/Sources/InfinitusWin/Routes.swift:136` (inside `input()`'s
  `SessionInput.deliver`, with `ttyOfPid: { _ in nil }`,
  `ancestorsOf: { _ in [] }` at `:138`);
  `windows/Sources/InfinitusWin/ControlServer.swift:278` (same nil'd
  providers at `:280-281`);
  `windows/Sources/InfinitusWin/Resume.swift:27` —
  `ResumeCoordinator(hosts: [], claudeDir:)`, comment `:22-25`
  "`hosts: []` is the whole reason this is safe on Windows… every
  delivery is a peer write or nothing", `socketSend` swapped to
  `NamedPipe.send` at `:28-34`.
  `windows/Sources/InfinitusWin/ResumeSupervisor.swift:24` restates it.
- Documented: `windows/README.md:549`, `:552`
  (`{"outcome":"noSurface"}`), `:569`, `:606`.
- **Asserted by the smoke test**: `windows/smoke.ps1:234-253` requires
  `POST /sessions/<pid>/input` with `kind:key` to answer
  `"outcome":"noSurface"`, and `:252` is the assertion. **That test
  breaks by design when keys land** — it must become conditional, not
  deleted.

### ConPTY: absent

Case-insensitive grep for `ConPTY|CreatePseudoConsole|pseudoconsole`
across the whole repo: **no matches.** No binding, no stub, no plan.
Nor is there COM/interop precedent generally — the closest existing
Win32 flat-API use is `DwmSetWindowAttribute`
(`windows/Sources/InfinitusTrayWin/WinDark.swift:112`).

### The branch ConPTY would slot into

- `Sources/InfinitusCore/SessionResume.swift:73` — `deliver`'s branch:
  `if session.canUseSocket, socketSend(session, text) { return "socket" }`,
  falling to the host loop at `:76-83` (`PtyNudge.nudge`, channel =
  `host.name`, `nil` on `.running`, `continue` on
  `.capturedInput`/`.noSurface`). Contract at `:66-71`: "A terminal host
  only for a record without a usable socket, or when the send fails —
  never both (two prompts)."
- `SessionResume.swift:35-44` — `hosts` and default `socketSend`
  (`PeerSocket.send`) as injectable fields; `:52-56` the initializer
  Windows already calls.
- Phone input's parallel ladder:
  `Sources/InfinitusCore/SessionInput.swift:288-292` (owned stdin, then
  socket → `channel: "socket"`), `:300-312` (pty loop →
  `channel: "pty"`), `:313-319` (outcome ladder, `noChannel` vs
  `noSurface`), and **`:234-246` the `.key` branch — owned first, then
  pty only, `Reply(outcome: "noSurface")` when `hosts` is empty. That
  single fact is why Windows keys are a no-op.**
- Contrast: the Linux tray passes real hosts —
  `Sources/InfinitusTray/InfinitusTray.swift:683-684`
  (`hosts: PtyHosts.available()`).

### What the daemon already owns

`windows/Sources/InfinitusWin/OwnedSessionsBox.swift:11` the box; `:16`
`existing` (never creates); `:21` `get(make:)`; `:32` `installShutdown()`
(atexit + `SetConsoleCtrlHandler`); `:56` `stopOwned()`. And
`Sources/InfinitusCore/OwnedSessions.swift:287` `deliver(_:record:)` —
the owned-**stdin** lane, `channel: "stdin"` at `:290`. Recent branch
work put this in: `e8af351 windows: the daemon owns headless claude
sessions (#151)`, `56cb49e owned: ClaudeLocator finds claude on Windows`.

**This is the phase's real leverage.** The daemon already spawns and
owns sessions and already writes to their stdin. A ConPTY changes *how*
it spawns them (pty instead of pipes) so that reads become a screen and
writes become keystrokes.

## Design

### Shape

New file `windows/Sources/InfinitusWin/ConPtyHost.swift`, conforming to
`InfinitusCore.PtyHost`. Because the protocol is already unfenced on
Windows (`PtyHosts.swift:3`), this is a plain conformance in the
Windows target — **no core edits to the protocol**.

Win32 surface needed: `CreatePseudoConsole` / `ResizePseudoConsole` /
`ClosePseudoConsole` (kernel32), plus `CreatePipe`,
`InitializeProcThreadAttributeList` +
`UpdateProcThreadAttribute(PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE)` and
`CreateProcessW` with `EXTENDED_STARTUPINFO_PRESENT`. All flat C APIs,
so no COM interop — which matters, because the codebase has no COM
precedent at all. `kernel32` needs no new `.linkedLibrary`; confirm
during the spike whether the Swift Windows SDK's `WinSDK` module
re-exports the pseudoconsole symbols (they are newer than much of
`WinSDK`'s surface, and a missing declaration is the first thing that
will bite).

### The four protocol members

- `surfaces()` — the daemon's own ConPTY-hosted sessions, one
  `PtySurface` each. `tty` is meaningless on Windows: leave it nil and
  match on **pid lineage** instead. That is why the phase must also
  supply real `ancestorsOf` (today `{ _ in [] }` at `Routes.swift:138`)
  — the daemon is the parent, so lineage is knowable without `/bin/ps`.
  Do **not** try to make `ProcessFacts` (`PtyHosts.swift:73-103`) work;
  it is `/bin/ps` and `/dev/<tty>` and has no Windows meaning. Inject
  the providers instead.
- `sendLine` / `sendEsc` — write to the ConPTY input pipe. `sendEsc` is
  `\u{1b}`; `sendLine` is text + `\r`. Straightforward.
- **`readScreen(ref:lines:)` — the hard part.** ConPTY emits a VT
  stream, not a screen. To answer `PtyNudge`'s questions the host must
  keep a **terminal emulator's worth of state**: a scrollback ring of
  the last N lines with enough VT handling (CSI cursor moves, erase,
  scroll regions, and Claude Code's own redraws) that the rendered text
  contains the markers `PtyNudge.swift:12-18` looks for. A naive
  "append all bytes, strip escapes" buffer will *sometimes* contain the
  marker and sometimes not, depending on how the TUI repainted — which
  produces an intermittently-wrong nudge decision, the worst possible
  failure mode for a feature that types into someone's session.

  **This is the phase's actual cost and its main risk.** Budget it as
  the work; treat `sendLine` as trivial by comparison. Scope the
  emulator to exactly what the markers need (a cursor, a line ring,
  erase-line/erase-display, no colors, no alt-charset), and pin it with
  fixture tests over recorded VT byte streams.

### Spawning under a ConPTY

Extend the owned-session spawn path (`OwnedSessions`, used via
`OwnedSessionsBox.get(make:)`) with a ConPTY mode. Keep it **a distinct
mode, not a replacement**: the existing pipe-owned session is what
`channel: "stdin"` delivery depends on
(`OwnedSessions.swift:287-290`), it works today, and a ConPTY session
behaves differently (see "What breaks"). Selection is explicit —
`--conpty` on the spawn, or a daemon flag — and **off by default**.

### Wiring, once a host exists

- `Routes.swift:136`, `ControlServer.swift:278`, `Resume.swift:27` —
  `hosts: []` becomes the ConPTY host list (empty when the feature is
  off, so today's behaviour is the default).
- `Routes.swift:138`, `ControlServer.swift:280-281` — real
  `ancestorsOf`; `ttyOfPid` stays nil-returning.
- **`Routes.swift:86` — `keys` becomes per-session**, not a constant:
  true for a session the daemon hosts under a ConPTY, false otherwise.
  This is the honest wire answer and the phone already gates its
  composer on it. Do not flip it to a blanket `true`.
- Note phase 03 extracts these delivery call sites into one helper; if
  03 has landed, this phase edits the helper instead of three sites.

### What breaks (state it in the docs, not after)

- **Interaction.** A session under the daemon's ConPTY is not in the
  user's Windows Terminal tab. They cannot type into it directly; the
  daemon is the terminal. That is a real behaviour change and the
  reason this is opt-in per session.
- Rendering: ConPTY negotiates its own size. `ResizePseudoConsole`
  exists, but nobody is watching a window, so pick a fixed sane size
  (wide enough that Claude Code's TUI does not wrap the marker strings —
  `PtyNudge.screenLines = 40` hints at the vertical need).
- Detach/reattach is not free. If the daemon exits, the ConPTY closes
  and the session dies —
  `OwnedSessionsBox.installShutdown()` (`:32`) and `stopOwned()` (`:56`)
  already handle owned-session teardown; ConPTY sessions inherit that
  lifetime. A user must understand their session is tied to the daemon.
- `windows/smoke.ps1:252` asserts `noSurface` for keys and will fail;
  it must become conditional on the feature being off.

### Existing terminal-spawned sessions stay out of reach

Unchanged and unchangeable by this phase. Those sessions have a named
pipe (`NamedPipeClient.swift:67`) and nothing else — no pty to read, no
input handle we own. `keys: false` for them is not a limitation to fix
here; it is the truth.

## Test plan

- `swift build --product infinitus-win` (one `--product` per
  invocation); `swift test` under `. .\windows\env.ps1`, never setting
  `INCLUDE`/`LIB` (`windows/env.ps1:9-12`).
- **The VT emulator is the testable core** and it must be tested
  fixture-first: recorded byte streams from a real Claude Code session
  (a limit stop, a menu open, a running turn) → asserted `readScreen`
  output containing/not containing each `PtyNudge` marker
  (`PtyNudge.swift:12-18`). These are pure-Swift tests, no ConPTY
  needed, and they should exist before any spawn code.
- `PtyNudge` itself is already testable through `CommandRunner`
  (`PtyHosts.swift:23`) — reuse that seam rather than driving a real
  pty in unit tests.
- Live ConPTY tests belong in `windows/Tests/InfinitusWinTests/` and
  should **XCTSkip when the feature flag is off or `CreatePseudoConsole`
  is unavailable** — CI runners are `windows-2022` with the windows job
  `continue-on-error: true`, so a hard dependency on spawning a real
  interactive `claude.exe` there is not viable.
- `windows/smoke.ps1:234-253` — make the `noSurface` assertion
  conditional; add a keys-work step gated on a ConPTY session existing.
- Perf: this phase adds a **reader thread per ConPTY session**. That is
  event-driven (blocking read), not a poll, so it should idle at zero —
  but Windows has no automated idle-CPU gate (see phase 07), so measure
  by hand and record the number, the way
  `windows/README.md:703` records 0.13% / 30 MB for the panel.

## Acceptance criteria

- [ ] `ConPtyHost` conforms to `PtyHost` with no changes to
      `Sources/InfinitusCore/PtyHosts.swift`.
- [ ] `readScreen` renders a real Claude Code limit-stop screen such
      that every `PtyNudge` marker is found; pinned by fixture tests
      over recorded VT streams.
- [ ] A daemon-spawned ConPTY session accepts a `key` press and a nudge;
      the reply names the pty channel.
- [ ] `keys` in the tail response is **per-session**, true only for
      ConPTY-hosted sessions.
- [ ] With the feature off, behaviour is byte-identical to today:
      `hosts: []`, `keys: false`, `noSurface`, and
      `windows/smoke.ps1` green unchanged.
- [ ] A terminal-spawned session still reports `keys: false` — no
      pretence.
- [ ] The docs state that a ConPTY session is not typeable in the user's
      own terminal and dies with the daemon.
- [ ] Measured idle CPU with one ConPTY session attached is recorded and
      near zero (no polling reader).

## Parallelization notes

**Owns exclusively:** `windows/Sources/InfinitusWin/ConPtyHost.swift`
(new), the VT-emulator source and its fixture tests, and the ConPTY
spawn mode inside the owned-session path.

**Edits (shared):** `windows/Sources/InfinitusWin/Routes.swift` (`:86`,
`:136`, `:138`), `windows/Sources/InfinitusWin/ControlServer.swift`
(`:278`, `:280-281`), `windows/Sources/InfinitusWin/Resume.swift`
(`:27`), `windows/smoke.ps1` (`:234-253`).

**Conflicts with phase 03** (same three delivery call sites — 03
extracts them into one helper) and **with phase 04** (`Routes.swift`,
different region). Run this **after 03**, so it edits one helper instead
of three sites. Never concurrently with 03.

**Safe beside:** phases 01, 02, 06, 07.

**Sequence it last** among the daemon phases, and treat it as droppable.

## Risks + open questions

- **The VT emulator is the risk.** Getting it 90% right yields
  intermittently wrong nudge decisions — worse than `keys: false`,
  because the failure types into a live session. If the fixture tests
  cannot be made to pass reliably, **stop and keep `keys: false`**;
  that is a legitimate outcome of this phase.
- Does `WinSDK` expose `CreatePseudoConsole` and the
  `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` constant? If not, they need
  manual declaration — cheap, but discover it first.
- Interaction loss is a genuine product regression for the affected
  session. Opt-in per session is the mitigation; a user who opts in
  globally will be unhappy.
- CI cannot meaningfully exercise a real interactive `claude.exe`; the
  live tests will be skipped in practice, so the fixture tests carry the
  whole safety burden.
- Open: is nudging even wanted on Windows? The pipe lane already
  delivers resume messages (`Resume.swift:28-34`,
  `windows/README.md:582-608`), and pty is the fallback for when the
  pipe is gone. Quantify how often that actually happens before paying
  for an emulator — if the pipe is reliable, this phase buys `key`
  presses only.
- Open: `PtyNudge.screenLines = 40` and `settle = 1.0` were tuned
  against tmux/iTerm. Do they hold against ConPTY's repaint timing?

## Estimated size

**L.** `sendLine`/`sendEsc`/spawn are S; `readScreen` with enough VT
state to be trustworthy is the bulk, and the fixture corpus has to be
recorded from real sessions. Optional and last for good reason.
