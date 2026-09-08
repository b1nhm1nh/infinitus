# Phase 01 — the cswap engine on Windows

## Goal

Let `CswapLocator` find a Windows cswap install so the adapter that is
already wired everywhere in `windows/` starts answering, and the tray's
engine panes go live instead of reading "not found". cswap stays one
`AccountEngine` adapter behind `cswap … --json` subprocesses; nothing in
this phase may make any other feature require it.

## Non-goals

- No second engine (CLIProxy, 9Router, Codex) — `windows/README.md:713-714`
  lists those as a separate gap.
- No account policy of our own: auto-swap, ordering and thresholds stay
  the engine's knobs. The panes set them and report refusals verbatim.
- No install/bootstrap of cswap from the app. A missing engine is the
  normal case, not an error (`CswapFleet.swift:12-13`).

## Current state

The adapter is complete and the call sites already exist; only the
locator is POSIX-only, so every one of them takes its `nil` branch.

- `Sources/InfinitusCore/Engines/Cswap/CswapCLI.swift:6-12` —
  `defaultCandidates(home:)` returns three POSIX paths
  (`~/.local/bin/cswap`, `/opt/homebrew/bin`, `/usr/local/bin`). No
  `.exe`, no `%LOCALAPPDATA%`. `isExecutableFile` never matches on
  Windows.
- `Sources/InfinitusCore/Engines/Cswap/CswapCLI.swift:14-26` — `locate()`
  is otherwise portable; the `INFINITUS_CSWAP` override at `:21-24`
  already works on Windows (empty string = "no engine", the onboarding
  fixture).
- **This box has the engine**: `C:\Users\BM\.local\bin\cswap.exe` exists
  (`uv tool install claude-swap`, alongside `claude-swap.exe`). So the
  only thing missing is the candidate list.
- **Prior art on another branch.** `git show
  windows-remote:Sources/InfinitusCore/Engines/Cswap/CswapCLI.swift:7-16`
  carries exactly this fence — `%USERPROFILE%\.local\bin\cswap.exe`,
  `%LOCALAPPDATA%\Programs\cswap\cswap.exe`,
  `%LOCALAPPDATA%\pipx\venvs\claude-swap\Scripts\cswap.exe`, commented
  "verified on this box 2026-09-04". `win-apps` branched from
  `3fa96ea` and does not contain it (`git merge-base --is-ancestor
  windows-remote win-apps` → false; the diff shows `+1 -13` removing the
  fence). **Phase 1 is largely a restore, not a discovery** — read that
  blob first.
- Consumers already on `CswapLocator.locate()`, all dark today:
  - `windows/Sources/InfinitusWin/CswapFleet.swift:230` — the `run()`
    that every account read goes through; `:87`, `:147`, `:170` guard
    switches with `.noEngine`.
  - `windows/Sources/InfinitusWin/Resume.swift:91` — prints
    `engine: <path>`; `windows/README.md:468` shows it already resolving
    `C:\Users\BM\.local\bin\cswap.exe`, i.e. that README was recorded
    against the `windows-remote` locator, not this branch's.
  - `windows/Sources/InfinitusTrayWin/Panes/CswapPane.swift:16` — the
    pane's `badge` liveness dot; `:311-315` the engine-path label;
    `:328-336` version + `configList` for the spec-driven form;
    `:419` upgrade; `:455-462` `config set|unset`.
  - `windows/Sources/InfinitusTrayWin/Panes/AccountsPane.swift` — eight
    sites: `:401`, `:425`, `:468`, `:510`, `:544`, `:566`, `:645`,
    `:681`, each returning `"cswap not found"`.
  - `windows/Sources/InfinitusTrayWin/Panes/PushPane.swift:342`, `:396`,
    `:431`, `:459`; `Panes/DevicesPane.swift:822`, `:902`;
    `Panes/ActivityPane.swift:77`, `:170`; `Panes/AboutPane.swift:441`.
  - `windows/Sources/InfinitusTrayWin/TrayFleet.swift` —
    `engineIndicator()` returns nil without the engine, so the panel
    footer shows no engine at all.

## Design

One core change plus a JSON/version contract check. The blast radius is
deliberately one function.

**`Sources/InfinitusCore/Engines/Cswap/CswapCLI.swift`** — fence
`defaultCandidates` with `#if os(Windows)`, restoring the
`windows-remote` list. Order matters (first hit wins): uv's
`~\.local\bin` first because that is what `uv tool install claude-swap`
produces, then a `Programs\cswap` install, then pipx's
`Scripts\cswap.exe`. Read `LOCALAPPDATA` from the environment with a
`\AppData\Local` fallback so a stripped environment still resolves.

Add a fourth lane the `windows-remote` version lacks: **PATH**. A user
who installed via plain `pip install --user` lands in a Python
`Scripts` dir that none of the three literals name. There is already a
PATH walker to copy the shape from —
`windows/Sources/InfinitusWin/InfinitusWinMain.swift:229-238` (`which`,
splitting on `;`, trying `.exe`/`.cmd`/`""`) — but it lives in the
daemon target where the tray cannot reach it. Put the resolver in core
beside `locate()` so both products and `infinitusctl` share one answer,
and leave `InfinitusWinMain.which` alone (it is for `qrencode`, a
different concern; merging them is the speculative abstraction CLAUDE.md
warns off).

`.cmd` matters: a pip console-script shim can be a `.cmd`, and
`Process.executableURL` cannot run a `.cmd` directly — it needs
`cmd.exe /c`. Rather than teach `CswapCLI.run` a shell (an argv-quoting
hazard, and secrets travel on stdin precisely to stay out of argv),
**accept only `.exe` on Windows** and let a `.cmd`-only install read as
"not found". Document it in `windows/README.md`; the fix for such a
user is `uv tool install`.

**Version / JSON contract.** `CswapPane` already calls `cli.version()`
and `cli.configList()` (`:328-336`), and `CswapFleet.read()` decodes
`AccountList` (`CswapFleet.swift:54-57`). What is unverified is whether
the Windows wheel of claude-swap emits the same JSON as the macOS one.
Add a `--json` shape probe to the phase's acceptance rather than new
code: run `cswap list --json`, `config list --json`, `--version`
against the real `cswap.exe` and confirm they decode into the existing
core types. If a field differs, the fix is upstream in claude-swap
(CLAUDE.md: missing knob → upstream PR, never a fork), and the phase
records the divergence instead of adding a Windows-only decoder.

One real Windows wrinkle to check while probing: `CswapFleet.run()`
(`:229-252`) reads both pipes to EOF **before** the timeout loop, and
the README (`windows/README.md:631-635`) records that cswap reports
failures as JSON on stdout with empty stderr and exit 1. That behaviour
is already handled; do not change it.

**No `#if os(Windows)` in windows/.** Everything under `windows/` is
already inside the manifest's `#if os(Windows)` fence
(`Package.swift:75-116`), so source-level fences there are noise. The
only new fence is the one in core.

**Package.swift / CI: no change.** `InfinitusWin` and `InfinitusTrayWin`
already depend on `InfinitusCore` (`Package.swift:88`, `:99`), and
`windows/ci.ps1` already builds both products and runs `swift test`.

## Test plan

- `swift build --product infinitus-win`, then
  `swift build --product infinitus-tray-win` — one `--product` per
  invocation (CLAUDE.md; two flags build only the last). `windows/ci.ps1`
  already does this in the right shape.
- `swift test` under `. .\windows\env.ps1`. Do not set `INCLUDE`/`LIB`
  in that shell — `windows/env.ps1:9-12` records that either one makes
  the toolchain skip MSVC auto-detection and fail on `errno.h`. zlib
  comes from the vendored `windows/Sources/CZlib` target
  (`Package.swift:44-45`), so nothing here needs a system zlib.
- **Real coverage, no skips.** `defaultCandidates` is pure string work
  over an injected `home:` and an injected `exists:` closure, so the
  Windows list is testable on every platform. Add cases to the existing
  cswap locator tests asserting: the `.exe` suffix on Windows; that
  `LOCALAPPDATA` is honoured and falls back; that PATH resolution finds
  a fixture; that a `.cmd`-only install resolves to nil. Gate the
  expectations with `#if os(Windows)` inside the test body, the idiom
  already used at `Tests/InfinitusCoreTests/EnginePaneCoreTests.swift:65`.
- One manual pass on the box with the real engine: `infinitus-win resume
  --explain` prints the `cswap.exe` path (`Resume.swift:91`);
  `infinitus-win control switch` reports the engine's own words;
  the tray's cswap pane shows a version and a populated config form.
- Fixture path unchanged: `INFINITUS_ACCOUNTS_JSON` still renders gauges
  without an engine (`windows/README.md:705-708`), and
  `INFINITUS_CSWAP=""` still simulates a box with none.

## Acceptance criteria

- [ ] `CswapLocator.locate()` returns `C:\Users\BM\.local\bin\cswap.exe`
      on this box with no environment override set.
- [ ] `INFINITUS_CSWAP=""` still yields nil (onboarding fixture intact);
      `INFINITUS_CSWAP=<path>` still pins.
- [ ] macOS/Linux `defaultCandidates` output is byte-identical to today.
- [ ] `cswap list --json`, `config list --json` and `--version` from the
      Windows wheel decode into the existing `AccountList` / `ConfigList`
      types with no Windows-only decoder; any divergence is written down
      and filed upstream instead of forked.
- [ ] The tray cswap pane shows the engine path, a version, and a config
      form whose entries round-trip through `config set|unset`.
- [ ] The accounts pane lists real accounts and a click asks the engine
      to switch, reporting a refusal verbatim.
- [ ] `windows/README.md` "Not Yet Implemented" (`:709-717`) no longer
      implies cswap is unreachable, and the `.cmd` limitation is stated.
- [ ] Idle CPU with the panel open unchanged (no new timer; this phase
      adds no motion).

## Parallelization notes

**Owns exclusively:** `Sources/InfinitusCore/Engines/Cswap/CswapCLI.swift`
and the cswap-locator test file.

**Safe beside:** phases 02, 03, 04, 05, 06, 07. This phase touches one
core file that no other phase needs, and reads (never edits) the
`windows/` panes. Phase 06 edits pane files but not `CswapPane`,
`AccountsPane`, `PushPane`, `DevicesPane`, `ActivityPane` or
`AboutPane`'s cswap call sites — those lines only need the locator to
start returning non-nil, which is a behaviour change, not a diff. Both
phases may want a line in `windows/README.md`; that file is the one
collision risk across the whole plan set, so **README edits are
appended in the merge, not written by the implementer** — each phase
reports its README sentence instead of editing.

## Risks + open questions

- The Windows claude-swap wheel's JSON may not match. Mitigated by
  probing before writing decoders, and by the upstream-not-fork rule.
- Restoring the `windows-remote` fence risks reintroducing whatever made
  it absent from `win-apps`. It looks like branch divergence rather than
  a revert — worth one `git log windows-remote -- <that file>` check
  before assuming.
- `isExecutableFile` on Windows is a weaker signal than on POSIX (no
  exec bit). A same-named non-executable file would resolve and then
  fail on `run()`. Acceptable: the failure surfaces as the engine's own
  error, which is what every call site already renders.
- Open: does the Windows wheel support `cswap upgrade`
  (`CswapPane.swift:419` calls it)? If it self-updates via pip it may
  need the interpreter, not the shim.
- Open: `%LOCALAPPDATA%\pipx\venvs\...\Scripts` was carried from
  `windows-remote` unverified on a pipx box. Keep it, cheap to try.

## Estimated size

**S.** One fenced function plus a PATH walker, restored from a known-good
blob; the acceptance probing is the bulk of the work.
