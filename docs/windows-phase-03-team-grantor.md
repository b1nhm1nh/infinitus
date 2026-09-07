# Phase 03 — the team control grantor on the daemon

## Goal

Mount a team fetch loop on `infinitus-win` so a Windows box can answer
commands a teammate has been granted — the Mac's lane-4 grantor pass,
running on the daemon's cycle. Execution reuses the delivery lane the
daemon already has (owned stdin first, then the named pipe), and the
tray shows who is driving and lets the user revoke.

## Non-goals

- No new team crypto, no new command kinds, no grant model of our own.
  `TeamControl` / `TeamGrants` are consumed as-is.
- No driver side (this box sending commands to someone else's box) —
  `TeamControlDrive` stays unused here; grantor only.
- No pty/send-keys. A `key` on an unowned session keeps answering
  `noSurface` honestly (that is phase 05's problem, if ever).
- No HTTP team routes on the daemon. The grantor is a git lane.

## Current state

**Depends on phase 02.** `TeamGit.swift:398` still runs
`/usr/bin/env`, so no fetch can happen on Windows at all. Everything
below is unreachable until that resolves.

**But the types are already linked in.** `Package.swift:11-13` gives
`InfinitusCore` no `sources:`/`exclude:` list, so all 41 `Team/` files
compile on every platform, and `Package.swift:88` has `InfinitusWin`
depending on `InfinitusCore`. `TeamControl`, `TeamGrants` and
`TeamControlStore` are **in the `infinitus-win` binary today and simply
never called** — grepping `Team` across `windows/Sources` returns zero
matches.

### How the Mac does it

- `Sources/Infinitus/TeamModel.swift:21` — `loopInterval = 300`; the
  model owns no timer, it rides AppModel's existing refresh tick.
- `Sources/Infinitus/TeamModel.swift:245` — `refreshIfStale(_:)`, the
  tick entry, guarded on `loopRunning`/`busy` and throttled to 300 s.
- `Sources/Infinitus/TeamModel.swift:260` — `loop(sources:publish:)`,
  one pass; `:276` — `_ = try client.fetch()`
  (`Sources/InfinitusCore/Team/TeamClient.swift:199`).
- `Sources/Infinitus/TeamModel.swift:80` — `onFetched` seam; `:278`
  `fetchedHook?(client)` fires **right after the fetch, before**
  auto-approve and publish.
- `Sources/Infinitus/AppModel.swift:1245` — the wiring:
  `team.onFetched = { client in mirrorServer.teamControl.storePass(client) }`.
- `Sources/Infinitus/MirrorServer.swift:333` — `storePass(_:)` hops onto
  `MirrorTeamControlBox.queue` so an HTTP request cannot interleave.
- `Sources/InfinitusCore/Team/TeamControlStore.swift:31` —
  `grantorPass(client:endpoint:handled:now:)`, the pass proper; `:40`
  `handle(file, endpoint:&)` per unhandled command; `:44`
  `client.publish(kind: TeamKinds.ack, …)`; `:47` sweeps own acks older
  than `2 * storeTTL`.
- `Sources/InfinitusCore/Team/TeamControl.swift:317` — `handle(_:endpoint:)`
  (verify then execute); `:324` the execute call site:
  `endpoint.execute(v.command.action, v.command.text, v.pid)`; `:238`
  the injected slot; `:270` `verify(_:endpoint:)` implementing spec §4
  steps 1-7.
- The Mac's `execute` closure: `Sources/Infinitus/MirrorServer.swift:527-532`
  — `mirrorInputQueue.sync { box.deliver(pid, request, from: "team") }`,
  into `AppModel.deliverSessionInput` (`AppModel.swift:1471`) and on to
  `SessionInput.deliver(request:record:hosts:claudeDir:owned:)`
  (`AppModel.swift:1504-1506`).
- `Sources/InfinitusCore/SessionInput.swift:190` — `deliver(...)`;
  `owned` is asked **first** (`:205`, short-circuits at `:218`, `:234`,
  `:288`), then `socketSend` (default `PeerSocket.send`, `:198-204`).

### What the daemon has and lacks

- **No periodic team anything.** `windows/Sources/InfinitusWin/InfinitusWinMain.swift:255`
  is `serve(_:)`; `:296-297` builds `OwnedSessionsBox()` and
  `installShutdown()`; `:298` builds `Routes.handler(...)`; `:316-317`
  starts `ControlServer` and records state; `:320-329` is **the only
  optional periodic subsystem** — `ResumeSupervisor` behind
  `--auto-resume`; `:331` `RunLoop.main.run()` holds the timers.
- The tick to copy: `windows/Sources/InfinitusWin/ResumeSupervisor.swift:30`
  `tickSeconds = 60`; `:56` idempotent `start()`; `:70-74`
  `DispatchSource.makeTimerSource(queue: .global(qos: .utility))` +
  `schedule(repeating:)` + `resume()`; `:97` `plan(now:list:)` —
  **decision split from delivery for testability**, the pattern this
  phase must follow.
- **The execute lane is fully assembled already.**
  `windows/Sources/InfinitusWin/Routes.swift:120` —
  `input(pid:request:claudeDir:owned:deliverOverride:log:)`; `:133`
  `let deliver = deliverOverride ?? owned.existing?.deliver`; `:134-142`
  the `SessionInput.deliver(...)` call with `socketSend:` =
  `NamedPipe.send` and `owned:` = the box's deliver, and `hosts: []` at
  `:136`.
- `windows/Sources/InfinitusWin/OwnedSessionsBox.swift:11` the box;
  `:16` `var existing: OwnedSessions?` (never creates — a miss must not
  pay for locating `claude`); `:21` `get(make:)`; `:32`
  `installShutdown()`.
- `windows/Sources/InfinitusWin/NamedPipeClient.swift:67` —
  `send(text:record:claudeDir:timeout:)`, `PeerSocket.frames` verbatim;
  `:17` `isListening` (side-effect-free `WaitNamedPipeW` probe); `:26`
  `write`; `:78` `ownAddress(pid:)`.
- The same lane exists a second time at
  `windows/Sources/InfinitusWin/ControlServer.swift:275-285` (the local
  control socket's `message`), also `hosts: []` (`:278`).
- `windows/Sources/InfinitusWin/ControlServer.swift:210-322` — the
  route table (`status`, `sessions`, `snapshot`, `switch`, `message`,
  dispatch at `:307-322`). No team verbs.

### The model a Windows grantor constructs

`Sources/InfinitusCore/Team/TeamControl.swift`: `:12` `storeTTL = 600`
(**must exceed the grantor's fetch cadence** or commands expire
unanswered), `:17` `Command`, `:36` `Ack`, `:57` `Outcome`, `:132-134`
`commandPath`/`ackPath`/`hostnamePath`, `:142` `Endpoints`, `:185`
`SeenIDs` (persisted replay set, `control-seen.json`), `:211`
`RateLimit` (5 commands / 10 s per driver), **`:233` `Endpoint` — the
main thing to construct**, init `:246`, `:255` `Verified`.
`Sources/InfinitusCore/Team/TeamGrants.swift`: `:9` the struct,
`:10-19` capability constants (`driveCapabilities` = send/approve/mode/
resume/key), `:23` `Sessions` (`.all`/`.some`), `:47` `Grant`, `:63-71`
`file`/`load`/`save`, `:77` `add`, `:87` `remove(id:)` — **revoke is
deletion; nothing propagates, the next command just fails `noGrant`**,
`:97` `permits(kid:session:capability:roster:)`, `:106` `hints`.
`TeamControlStore.swift:10` `Handled` (`control-handled.json`), `:55`
`driverReap`.

## Design

### The supervisor

New file `windows/Sources/InfinitusWin/TeamSupervisor.swift`, modelled
directly on `ResumeSupervisor.swift`. Mount it in `serve` at
`InfinitusWinMain.swift:320-329`, right beside the resume supervisor,
behind its own flag — `--team-grant` (name it for what it does: this box
answers commands other people were granted). **Off unless asked for**,
the same posture `--auto-resume` takes and for a stronger reason: this
lane types into the user's sessions on a teammate's behalf.

Tick: a `DispatchSource` timer on `.global(qos: .utility)`, copying
`ResumeSupervisor.swift:70-74`. **Cadence must be well under
`storeTTL = 600`** (`TeamControl.swift:12`) or a command can expire
before the pass sees it. The Mac's 300 s is exactly half of it and is
the safe precedent; do not invent a faster one to feel responsive —
the driver-side latency budget is the store lane's, not ours.

Follow `ResumeSupervisor`'s **plan/apply split** (`:97` `plan(now:list:)`):
a pure function deciding what the pass would do, and a separate applier.
That is the only way this gets tested without a live remote.

The pass body is small because core does the work: fetch
(`TeamClient.fetch()`), then
`TeamControlStore.Store.grantorPass(client:endpoint:handled:now:)`
(`TeamControlStore.swift:31`). Serialize it against the HTTP handler the
way the Mac serializes on `MirrorTeamControlBox.queue`
(`MirrorServer.swift:333`) — the daemon's listener runs **one thread per
connection** (`WinHTTPServer.swift:91`), so `Routes.input` and a grantor
execute can genuinely race into the same session. A single lock or
serial queue owned by the supervisor, with `Routes`' delivery taking it
too, is the requirement. Do not skip this: the Mac's comment at
`MirrorServer.swift:333` exists because of it.

### The execute lane

`TeamControl.Endpoint.execute` (`TeamControl.swift:238`) is a plain
closure, so the Windows implementation is near-mechanical: build a
`SessionInput.Request` via `TeamControl.request(action:text:)`
(`:155`), then call the delivery that `Routes.swift:134-142` already
performs — owned stdin first (`owned.existing?.deliver`), then
`NamedPipe.send` as `socketSend`, with `hosts: []`.

**Factor that call out rather than writing a third copy.** It already
exists twice (`Routes.swift:134-142`, `ControlServer.swift:275-285`); a
grantor would make three. One internal helper in the `InfinitusWin`
target taking `(pid, request, owned, claudeDir)` and returning
`SessionInput.Reply`, called from all three. That is a surgical
refactor, not a speculative abstraction — the third caller is the
justification.

`hosts: []` is preserved deliberately. `SessionInput.swift:234-246` —
the `.key` branch tries owned, then pty only, and returns
`Reply(outcome: "noSurface")` when `hosts` is empty. So a granted `key`
on a session the daemon does not own reports `noSurface`, which is the
truth. `windows/Sources/InfinitusWin/Routes.swift:9-13` already states
this contract; the grantor inherits it.

**Grants live in the team dir, not in daemon config.**
`TeamGrants.file(teamDir:)` (`TeamGrants.swift:63`) is the store, and
`permits(kid:session:capability:roster:)` (`:97`) is the only
authorization decision — the daemon must never add a second check on
top (the same reasoning CLAUDE.md applies to account policy: one
decision-maker). Replay and rate limiting are likewise already in core
(`SeenIDs` `:185`, `RateLimit` `:211`) and must be wired, not
reimplemented — they are what stop a replayed command re-typing into a
session.

### What the tray shows

Add to the Team pane from phase 02 (do not create a second pane): a
**Drivers** section listing active grants — who (kid → roster name),
which sessions (`.all` or the list), which capabilities, since when —
read from `TeamGrants.load(teamDir:)`. Each row gets **Revoke**, which
is `TeamGrants.remove(id:)` + `save` (`:87`, `:71`). The pane must say
plainly that revoke is local and takes effect on the next command
(nothing is pushed to the driver), because `:87`'s semantics are exactly
that and a user will otherwise assume it interrupts work in flight.

Also surface the last pass: when it ran, how many commands it answered,
and the last refusal reason. The audit type exists —
`TeamControl.swift:304` `Audit`. Without this the feature is invisible
until something goes wrong.

**No new timer for the pane.** Read on open and on an explicit refresh;
the supervisor's tick is the only periodic work this phase adds, and it
is a git fetch on a utility queue, not a repaint.

## Test plan

- `swift build --product infinitus-win`, then `--product
  infinitus-tray-win` (one `--product` per invocation). `swift test`
  under `. .\windows\env.ps1`; no `INCLUDE`/`LIB` in that shell
  (`windows/env.ps1:9-12`); zlib is the vendored `CZlib`
  (`Package.swift:44-45`), which the team envelope needs.
- **Real coverage, no live remote:** a `TeamSupervisorTests` in
  `windows/Tests/InfinitusWinTests/` mirroring
  `ResumeSupervisorTests` — drive the pure `plan` over fixture
  commands/grants and assert the decisions (granted → execute;
  no grant → `noGrant`; replayed id → not re-executed; over rate limit
  → refused; expired past `storeTTL` → skipped). The existing suite
  drives account state through `INFINITUS_ACCOUNTS_JSON`
  (`windows/README.md:616-618`); the same fixture-injection posture
  applies here via `INFINITUS_TEAM_DIR` (`TeamPaths.swift:14-16`).
- Execute-lane coverage with `deliverOverride`
  (`Routes.swift:133` already accepts one) so a test asserts the
  grantor reaches the same delivery as the HTTP route without touching
  a real session.
- `Tests/InfinitusCoreTests/TeamControlStoreTests.swift:7-10` currently
  skips on Windows because `makeRemote` shells `/usr/bin/env git`. Phase
  02 converts that to a git-presence skip; **this phase should see it
  running for real** — it is the round-trip test for the pass itself.
- Manual on the box, two teams on one machine via `INFINITUS_TEAM_DIR`:
  grant a capability, send a command from the driver side
  (`infinitusctl team` control verbs,
  `Sources/InfinitusCLI/TeamControlCommand.swift`), watch the daemon
  answer and the ack land.
- Add a concurrency check: a grantor execute and a
  `POST /sessions/<pid>/input` at the same moment must not interleave
  frames into one pipe.

## Acceptance criteria

- [ ] `infinitus-win serve --team-grant` runs a fetch + grantor pass on
      a cadence below `storeTTL`; without the flag, nothing team-related
      runs and no team files are touched.
- [ ] A granted `message` from a teammate is delivered into the target
      session and acked; the transcript shows it.
- [ ] A command with no matching grant is refused with the core's own
      outcome string, not a Windows-specific one.
- [ ] A replayed command id is answered once (`SeenIDs` honoured); a
      driver over 5-in-10s is rate-limited.
- [ ] A granted `key` on an unowned session answers `noSurface`; on an
      owned session it works.
- [ ] Grantor execution and an HTTP input never interleave into the same
      pipe (serialized, like the Mac's `storePass` queue hop).
- [ ] The delivery call exists once in `InfinitusWin`, called by the
      route, the control socket and the grantor.
- [ ] The tray lists active drivers with capabilities and a working
      Revoke, and states that revoke applies to the next command.
- [ ] Idle CPU with the panel open unchanged; the only added periodic
      work is the git fetch on a utility queue.

## Parallelization notes

**Owns exclusively:** `windows/Sources/InfinitusWin/TeamSupervisor.swift`
(new), the delivery-helper extraction inside `InfinitusWin`, and
`windows/Tests/InfinitusWinTests/TeamSupervisorTests.swift` (new).

**Edits (shared, coordinate):**
`windows/Sources/InfinitusWin/InfinitusWinMain.swift` (the `serve` mount
at `:320-329`), `windows/Sources/InfinitusWin/Routes.swift` (`:134-142`
switches to the helper), `windows/Sources/InfinitusWin/ControlServer.swift`
(`:275-285` likewise), and the phase-02 Team pane (a Drivers section).

**Hard dependency:** phase 02. Do not start before its resolver lands —
every acceptance line here needs a working `git.exe`.

**Safe beside:** phases 01, 06, 07 — no file overlap. **Conflicts with
phase 04**: both mount something in `serve`
(`InfinitusWinMain.swift:320-329`) and 04 may touch `Routes.swift`
(`:51-56`). Run 03 and 04 in sequence, or split the mount site by
having whichever lands first introduce a small "optional subsystems"
block the second appends to. **Conflicts with phase 05** if that ever
ships: 05 flips `hosts: []` at `Routes.swift:136` and `keys: false` at
`:86`, the same lines this phase's helper extraction moves.

## Risks + open questions

- **The tick-vs-TTL relationship is the sharp edge.** A cadence above
  `storeTTL = 600` silently drops commands as expired, and it will look
  like a delivery bug. Assert the relationship in code, not just docs.
- Racing the HTTP thread into one named pipe is the second sharp edge;
  the Mac's queue hop is precedent, not decoration.
- This lane types into the user's sessions on someone else's behalf.
  Flag-gated off, revocable, rate-limited and replay-guarded by core —
  but the tray must make an active grant impossible to miss.
- `OwnedSessionsBox.existing` is deliberately non-creating
  (`OwnedSessionsBox.swift:16`), so a grantor's owned-stdin lane only
  works for sessions the daemon already owns. Grants over
  terminal-spawned sessions fall to the pipe, and to `noSurface` for
  keys. That is correct but will read as inconsistent to a user;
  the pane should say which sessions are drivable.
- Open: does `grantorPass` need the daemon to publish anything besides
  acks (`TeamControlStore.swift:44`) — e.g. a fleet doc, so the driver
  can see this box at all? `TeamFleetDoc.swift` exists; check whether a
  grantor that never publishes is discoverable.
- Open: `TeamControl.Endpoints` (`:142`) carries lan/hostname/rendezvous
  hints for `now.json`. Windows has no `NamedTunnel`
  (`windows/README.md:715-716`), so the hostname hint is empty — confirm
  a driver tolerates that and falls back to the store lane.

## Estimated size

**M.** The supervisor is a close copy of an existing one and core does
the protocol work; the cost is the serialization, the helper extraction
across three call sites, the fixture tests, and the pane section.
