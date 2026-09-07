# Infinitus on Windows — next implementation phases

Written 2026-09-07 from the repo on branch `win-apps`. Every claim in
these docs carries a `file:line` that was opened; where the brief's gap
analysis turned out to be wrong, the doc says so and cites the evidence.

## Structure: flat `NN-topic.md`, not directories

One file per phase, `docs/windows-phase-NN-topic.md`, plus this index.
**Why:** the repo's existing Windows plan set is exactly this shape —
`docs/plan-windows/{01-stack,02-feed-readonly,…,07-testing}.md` +
`README.md` + `TASKS.md` (on branch `windows-remote`; that directory is
not present in `win-apps`, though `windows/README.md:563` still
references `docs/plan-windows/05-custom-api.md` and `Package.swift:83`
cites `01-stack.md`). Matching it keeps one convention. Directories
would buy nothing — no phase needs sibling files.

Numbering is `01`–`07` as literal names, since `docs/plan-windows/` uses
`W1`–`W18` task ids and `01`–`07` doc numbers that describe a *different*
axis (the original port), so there is no sequence to continue. These are
`windows-phase-*` to keep them distinct from that set.

## Two corrections to the brief's gap analysis

Both were verified in code and change what the phases do:

1. **Phase 01 is largely a restore.** The Windows cswap candidates the
   brief asks for already exist on branch `windows-remote`
   (`git show windows-remote:Sources/InfinitusCore/Engines/Cswap/CswapCLI.swift:7-16`),
   commented "verified on this box 2026-09-04". `win-apps` branched from
   `3fa96ea` and lost them (`+1 -13`). `windows/README.md:468` shows
   `resume --explain` already printing `C:\Users\BM\.local\bin\cswap.exe`
   — that README was recorded against the other branch.
2. **Phase 06's placeholders do not exist.** `PlaceholderPane` is
   instantiated nowhere — grepping `windows/` returns only its own
   declaration at `Panes/PlaceholderPane.swift:7`. All 13 registered
   panes (`SettingsShell.swift:367-419`) are real classes. The actual
   gap is **five Mac panes with no Windows counterpart**: Profiles,
   Lock, Team, Machine, Animations.

A third, smaller one: **Team already compiles into `infinitus-win`
today** (`Package.swift:11-13` gives `InfinitusCore` no `exclude:`, and
`:88` links it), with Windows branches already written in
`TeamSecrets.swift:46` and `TeamIdentityExport.swift:65`. Phase 02's
blocker is one line — `TeamGit.swift:398`'s `/usr/bin/env`.

## The phases

| # | phase | goal | size | depends on | parallel-safe with |
|---|---|---|---|---|---|
| 01 | [cswap engine](windows-phase-01-cswap-engine.md) | Windows candidates + PATH so the locator resolves; the tray's engine panes go live | S | — | 02, 03, 04, 05, 06, 07 |
| 02 | [Team](windows-phase-02-team.md) | a `git.exe` resolver, store lanes green, CLI + one Team pane; nearby deferred with reasons | M | — | 01, 04, 05, 07 (**not 06**) |
| 03 | [Team control grantor](windows-phase-03-team-grantor.md) | a grantor pass on the daemon's cycle, executing over owned stdin + named pipe | M | **02** | 01, 06, 07 (**not 04, 05**) |
| 04 | [Push](windows-phase-04-push.md) | be honest: no APNs from Windows (Mac-keychain `.p8`); toast locally, record the relay option | S | — | 01, 02, 06, 07 (**not 03, 05**) |
| 05 | [ConPTY nudges](windows-phase-05-conpty-nudges.md) | spawn under a daemon-owned ConPTY to unlock keys; opt-in, existing sessions stay out of reach | L | 03 (soft) | 01, 02, 06, 07 (**not 03, 04**) |
| 06 | [Missing panes](windows-phase-06-missing-panes.md) | delete dead `PlaceholderPane`; ship Profiles, Lock, Machine | M | — | 01, 03, 04, 05, 07 (**not 02**) |
| 07 | [DComp spike](windows-phase-07-directcomposition-spike.md) | **Step 0: the Windows perf gate** (there is none); then one effect over the panel, or a recorded no | S+M | — | 01, 02, 04, 06 (**not 03**) |

Sizes: S ≤ ½ day, M ≤ 2 days, L > 2 days — the scale
`docs/plan-windows/TASKS.md` uses.

## Recommended parallel batches

**Batch 1 — 01 + 06 + 07-Step-0.** No dependencies, no shared files.
01 is core-only (`CswapCLI.swift`); 06 owns the tray's pane files and
`SettingsShell.swift`; 07's Step 0 owns `ci.ps1` and adds a `perf` route.
Step 0 goes first in the batch because it makes every later phase's
idle-CPU claim measurable instead of asserted.

**Batch 2 — 02 + 04.** 02 owns `TeamGit.swift`, `TeamPaths.swift`, the
core `GitLocator`, the `Team*Tests` suites and `TeamPane.swift`; 04 owns
the `/activities/token` region of `Routes.swift` and `TrayNotify.swift`.
02 must hand its one registration line to 06 (or the merge) rather than
edit `SettingsShell.swift`.

**Batch 3 — 03 alone.** Needs 02's resolver, and it refactors the three
`SessionInput.deliver` call sites (`Routes.swift:134-142`,
`ControlServer.swift:275-285`, plus its own) into one helper — which
collides with 04 (`Routes.swift`), 05 (same call sites) and 07
(`ControlServer.swift`). Give it the daemon to itself.

**Batch 4 — 07's spike, and 05 only if wanted.** Both are optional.
Run 05 after 03 so it edits one helper instead of three sites. 05 is
droppable: a clean "keep `keys: false`" is a legitimate outcome, and 07
succeeds equally by proving DComp cannot layer over these HWNDs.

## The one file every phase wants to touch

`windows/README.md`. To keep implementer agents from colliding on it,
**no phase edits it** — each reports the sentence or paragraph it would
add, and the merge applies them. This is stated in every phase doc.

Second-order collisions, already assigned: `SettingsShell.swift` → 06;
`Routes.swift` delivery lane → 03, `/activities/token` → 04, `keys:`/
`hosts:` → 05; `ControlServer.swift` delivery → 03, `perf` route → 07;
`Package.swift` → 07 only; `ci.ps1` → 07 only.

## Rules these phases inherit (by effect, from CLAUDE.md)

- cswap is one adapter; **no** phase may make another feature require
  it. Phase 01 exists to make it *findable*, not load-bearing.
- Engine touchpoints stay `cswap … --json` subprocesses; engine
  internals are never read.
- Secrets travel on stdin, never argv — relevant to phase 02's
  credential helper (the token already goes by environment, and stays
  there) and phase 04 (no key ever reaches a Windows box).
- Idle CPU near zero, and continuous motion goes through a compositor or
  does not ship. Phase 07 is shaped entirely by this, and it starts by
  building the gate Windows lacks.
- Surgical diffs, no speculative abstractions. Phase 03's helper
  extraction is justified by a *third* caller, not anticipation.
- Windows products are `infinitus-win` + `infinitus-tray-win` under
  `windows/`, fenced by `#if os(Windows)` in `Package.swift:75-116`;
  sources under `windows/` need no further fences.
- Build one `--product` per `swift build` invocation.
- Never set `INCLUDE`/`LIB` in the env.ps1 shell
  (`windows/env.ps1:9-12`); zlib is the vendored `windows/Sources/CZlib`
  target (`Package.swift:44-45`).
- Todos and research go to GitHub issues, not files. These are design
  docs for a specific batch of work, not a running log.
