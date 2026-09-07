# Phase 06 — the five missing panes (and the placeholder that isn't)

## Goal

Close the tray's settings gap against the Mac: five Mac panes have no
Windows counterpart at all. Also delete `PlaceholderPane`, which the
plan assumed was in use and which the audit found to be dead code — no
pane is a placeholder today.

## Non-goals

- Not the Mac's five-group sidebar or its row-level search index.
  Those are structural divergences, listed but not fixed here.
- No new pane concepts. Each pane is specced against its Mac
  counterpart; anything the Mac lacks does not appear here.
- No effects. The Animations pane is the one that exercises them and is
  explicitly deferred to phase 07's decision.

## Current state

### `PlaceholderPane` is dead code — correcting the premise

`windows/Sources/InfinitusTrayWin/Panes/PlaceholderPane.swift:7`
declares it; `:6`'s comment reads "Generic placeholder pane for wave-01
panes that are not yet implemented"; `:8` an injected instance
descriptor, `:9-11` the protocol stub, `:16-18` the only extra API,
`:20-23` `attach` making exactly one bold title label, `:25-32` `layout`,
`:34-38` empty `activate`/`deactivate` and `false` from
`command`/`notify`/`drawItem`, `:39-42` a constant `px(100)` height.

**Grepping `PlaceholderPane` across `windows/` returns exactly one hit —
its own declaration.** It is instantiated nowhere. The wave-01 scaffold
it existed for has been fully replaced.

### All 13 registered Windows panes are real

Single registration site:
`windows/Sources/InfinitusTrayWin/SettingsShell.swift:367` —
`let allDescriptors: [(PaneDescriptor, (PaneDescriptor) -> SettingsPane)]`,
consumed by the loop at `:423-443`.

| id | title | section | class | registration | descriptor |
|---|---|---|---|---|---|
| `display` | Display | general | `DisplayPane` | SettingsShell.swift:368-371 | Panes/DisplayPane.swift:12 |
| `accounts` | Accounts | general | `AccountsPane` | :372-375 | Panes/AccountsPane.swift:8 |
| `themes` | Themes | general | `ThemesPane` | :376-379 | Panes/ThemesPane.swift:14 |
| `push` | Push | general | `PushPane` | :380-383 | Panes/PushPane.swift:10 |
| `usage` | Usage | general | `UsagePane` | :384-387 | Panes/UsagePane.swift:7 |
| `utilization` | Utilization | general | `UtilizationPane` | :388-391 | Panes/UtilizationPane.swift:7 |
| `stats` | Stats | general | `StatsPane` | :392-395 | Panes/StatsPane.swift:7 |
| `activity` | Activity | general | `ActivityPane` | :396-399 | Panes/ActivityPane.swift:7 |
| `devices` | Devices | general | `DevicesPane` | :400-403 | Panes/DevicesPane.swift:10 |
| `about` | About | general | `AboutPane` | :404-407 | Panes/AboutPane.swift:12 |
| `cswap` | cswap | engines | `CswapPane` | :408-411 | Panes/CswapPane.swift:9-14 |
| `cliproxy` | CLIProxyAPI | engines | `CLIProxyPane` | :412-415 | Panes/CLIProxyPane.swift:9-14 |
| `9router` | 9Router | engines | `NineRouterPane` | :416-419 | Panes/NineRouterPane.swift:9-14 |

Supporting types:
`windows/Sources/InfinitusWinUI/SettingsCatalogWin.swift:22`
`PaneDescriptor` (fields `:38-44`: id, title, glyph, tintRGB, keywords,
section, badge); `:23-26` `enum Section { general, engines }` — **only
two sections**; `:28-36` `ProviderBadge { live, placeholder }` (the
`placeholder` flag is never set true by any pane);
`windows/Sources/InfinitusTrayWin/SettingsPane.swift:108-143` the
`SettingsPane` protocol;
`windows/Sources/InfinitusTrayWin/SettingsWindow.swift:5-10` a pure
façade forwarding to `SettingsShell.show(paneID:)`.

Stale comment: `SettingsShell.swift:366` says
`// 10 General + 3 Engine + 1 Legacy` = 14; the array holds 13.

### The Mac's 18 panes

Source of truth: `Sources/Infinitus/InfinitusApp.swift:198-310`,
`settingsTabs(...)`; type at
`Sources/Infinitus/StatusItemController.swift:20`.

Display `:210` (`DisplayPane.swift:6`), Accounts `:214`
(`AccountsPane.swift:580`), Themes `:219` (`ThemesPane.swift:10`), Push
`:223` (`NotifyPane.swift:95`), Usage `:227` (`UsagePane.swift:73`),
Utilization `:230` (`UtilizationPane.swift:130`), Stats `:235`
(`StatsPane.swift:12`), **Machine `:241`** (`MachinePane.swift:9`, gated
on `MachineModel.paneShown`, flag at `MachineModel.swift:16`),
**Profiles `:247`** (`ProfilesPane.swift:7`), Activity `:251`
(`ActivityPane.swift:6`), Devices `:256` (`SyncPane.swift:10`, renamed
from "Sync" 2026-09-02 per the comment at `:254`), **Lock `:261`**
(`LockPane.swift:8`, title at `LockModel.swift:14`), **Team `:265`**
(`TeamPane.swift:11`, title at `TeamModel.swift:20`), **Animations
`:270`** (`AnimationsDebugPane.swift:8`, gated on `model.debugMenu`),
About `:276` (`AboutPane.swift:353`), cswap `:283`
(`EnginesPane.swift:7`), CLIProxyAPI `:295` (`EnginesPane.swift:166`),
9Router `:302` (`EnginesPane.swift:308`→`:285`).

Mac grouping is five, not two:
`Sources/Infinitus/SettingsSidebar.swift:12-17`
`enum SettingsGroup { general, accounts, dashboards, engines, app }`,
assignment at `:29-38`, per-group content width at `:27` (dashboards
1100pt, rest 760pt). Mac-only search index:
`Sources/Infinitus/SettingsSearch.swift:11` `index(tabs:)`, per-pane
`searchEntries` dispatch `:26-34`.

### The diff — this is the spec

**Five Mac panes with no Windows counterpart:**

| Mac pane | Mac impl | Mac group | Windows |
|---|---|---|---|
| **Profiles** | `ProfilesPane.swift:7` | general | absent; unconditional on Mac → highest priority |
| **Lock** | `LockPane.swift:8` | general | absent; unconditional on Mac |
| **Team** | `TeamPane.swift:11` | accounts | absent; **owned by phase 02**, not this phase |
| **Machine** | `MachinePane.swift:9` | dashboards | absent; conditional even on Mac (`MachineModel.paneShown`) |
| **Animations** | `AnimationsDebugPane.swift:8` | app | absent; debug-only on Mac; exercises phase 07's effects |

Also unported but **not a top-level tab** (a sub-pane reached from
`ClaudeEnginePane` via `reliability:`, `InfinitusApp.swift:294`):
`Sources/Infinitus/ResumeReliabilityPane.swift`. Note that
`CswapPane.swift:31-35` already has resume-reliability controls inline,
so Windows covers that content differently — no action.

Mac's Team pane also has unported companion views
(`TeamIdentityPanels.swift`, `TeamInsightsPane.swift`,
`TeamMemberPane.swift`) — relevant to phase 02, not here.

## Design

### First: delete `PlaceholderPane`

`windows/Sources/InfinitusTrayWin/Panes/PlaceholderPane.swift` is
unreferenced. Delete the file. Also fix the stale count comment at
`SettingsShell.swift:366`. Consider dropping the never-set
`placeholder` flag on `ProviderBadge`
(`SettingsCatalogWin.swift:28-36`) — check for readers first; if the
Mac's badge shape has it too, leave it for parity.

### Then: three panes, in this order

**Scope decision: this phase ships Profiles, Lock and Machine. Team goes
to phase 02. Animations waits for phase 07.** Reasons: Team needs the
git resolver and the store lanes before a pane can show anything true;
Animations is a debug pane whose entire content is the effects that
phase 07 decides whether to build, and a Windows Animations pane with no
animations is a placeholder by another name — exactly what this phase is
deleting.

Each pane follows the established Windows pattern, no invention:

- A `PaneDescriptor` static (`CswapPane.swift:9-18` is the template:
  id, title, glyph, tintRGB, keywords, section, optional badge).
- Controls are real child HWNDs via `PaneControls`
  (`SettingsPane.swift:365-583`: `CreateWindowExW` at `:382`, `:412`,
  `:430`, `:451`, `:468`, `:490`), or an `SS_OWNERDRAW` canvas
  (`:485-497`) routed through `drawItem`/`WM_DRAWITEM`
  (protocol `:138`) when custom painting is needed.
- **Heed the handle-leak warning at `SettingsPane.swift:20-27`:**
  `layout` runs on **every** `WM_SIZE`, so transient GDI objects must be
  recycled or the 10k USER-handle quota is exhausted during a single
  window drag. This is the most likely way a new pane breaks the app.
- Background work through `ctx.async(_:then:)`
  (`CswapPane.swift:325-341`) — never block the message loop on a
  subprocess or a file scan.
- Numbers and strings come from **InfinitusCore**, never a second
  implementation. `windows/README.md:691-694` states the rule for the
  accounts panel (`GaugeMath`, `WeeklyRoll.displayPct`, `ResetLabel`,
  `AccountVitals`) and it applies here: read each Mac pane to find which
  core types it renders, and render the same ones.

**Profiles** — unconditional on the Mac and in `general`, so it is the
most visible gap. Read `Sources/Infinitus/ProfilesPane.swift:7` for the
model it drives and mirror the controls. Verify whether the underlying
profile store is core (portable) or Mac-only before designing the UI; if
it is Mac-only, that is a core-portability sub-task and the pane
follows it.

**Lock** — `Sources/Infinitus/LockPane.swift:8`, title from
`LockModel.swift:14`. Windows already has credential/secret primitives
(`windows/Sources/InfinitusWinUI/WinSecret.swift`, which uses
`ConvertStringSecurityDescriptorToSecurityDescriptorW` at `:68-77`), but
no biometric/Hello integration. Spec the pane against whatever
`LockModel` actually gates; if it depends on macOS
LocalAuthentication, the Windows pane must either use Windows Hello or
honestly omit that control — decide from the Mac source, and say which.

**Machine** — `Sources/Infinitus/MachinePane.swift:9`, gated by
`MachineModel.paneShown` (`MachineModel.swift:16`). Because it is
conditional even on the Mac, ship it behind the same gate. Note
`Tests/InfinitusCoreTests/MachineHealthTests.swift:5` already has a
Windows fence — read it first; it likely records which health signals
are unavailable here, which is the pane's content spec.

### Structural divergences: record, do not fix

- Two sections vs five (`SettingsCatalogWin.swift:23-26` vs
  `SettingsSidebar.swift:12-17`). Adding `accounts`, `dashboards` and
  `app` would re-sort every existing pane — a bigger, riskier change
  than the panes themselves. **Out of scope**, but with three more panes
  landing, the flat `general` list grows to 13; note it as the natural
  follow-up.
- Per-group content width (`SettingsSidebar.swift:27`) — no Windows
  equivalent, and `dashboards` at 1100pt suggests Machine/Stats want
  more room. Worth checking that Machine is legible at the Windows
  shell's fixed width.
- Search granularity: Mac indexes rows
  (`SettingsSearch.swift:26-34`), Windows matches title+keywords
  (`SettingsCatalogWin.swift:67-72`). Out of scope; give each new pane
  generous `keywords` to compensate.

## Test plan

- `swift build --product infinitus-tray-win` (one `--product` per
  invocation — two flags build only the last, CLAUDE.md). `swift test`
  under `. .\windows\env.ps1`; never set `INCLUDE`/`LIB`
  (`windows/env.ps1:9-12`).
- **Real coverage, existing suites to extend:**
  `windows/Tests/InfinitusWinTests/SettingsPanesDataTests.swift`,
  `SettingsShellTests.swift` and `EnginePanesWinTests.swift` already
  test pane data and shell behaviour without an HWND — that is where the
  new panes' pure logic goes. `SettingsCatalogWin` is explicitly the
  "testable without HWND" target (`Package.swift:76-77`), so descriptor
  registration, ordering, section assignment and keyword search are all
  assertable.
- Assert the catalog: 13 → 16 registrations, no duplicate ids, every
  descriptor's section valid, and the count comment matches.
- Deleting `PlaceholderPane` should break **no** test; if one references
  it, that is the only place it was used and the audit's "dead code"
  finding needs revisiting.
- No `XCTSkip` needed — this phase is Windows-only UI in a
  Windows-fenced target; the whole suite already only builds there.
- Manual: open each new pane, resize the window repeatedly (the
  handle-leak check from `SettingsPane.swift:20-27`), and confirm idle
  CPU with the settings window open stays near zero — no new timer, no
  repaint loop. `windows/README.md:703` (0.13% / 30 MB) is the
  reference figure to stay near.

## Acceptance criteria

- [ ] `PlaceholderPane.swift` is deleted and nothing references it.
- [ ] `SettingsShell.swift:366`'s count comment matches the array.
- [ ] Profiles, Lock and Machine panes exist, are registered, and render
      real data from InfinitusCore — not a title label.
- [ ] Machine is gated the same way the Mac gates it.
- [ ] Any Mac control with no Windows equivalent is **omitted with a
      stated reason**, never shown as a dead control.
- [ ] Dragging a resize across each new pane does not grow the process's
      USER-handle count.
- [ ] No new timer; idle CPU with the settings window open unchanged.
- [ ] The catalog tests assert 16 panes, unique ids, valid sections.
- [ ] Team and Animations are explicitly **not** added here.

## Parallelization notes

**Owns exclusively:** `windows/Sources/InfinitusTrayWin/Panes/PlaceholderPane.swift`
(deleted), the three new `Panes/ProfilesPane.swift`, `Panes/LockPane.swift`,
`Panes/MachinePane.swift`, and
**`windows/Sources/InfinitusTrayWin/SettingsShell.swift`** (the
registration array at `:367-419` and the comment at `:366`) — this phase
owns that file for the batch.

**Collides with phase 02:** phase 02 ships `Panes/TeamPane.swift` and
needs one registration line in `SettingsShell.swift:367`'s array. Since
this phase owns that file, **phase 02 must not edit it** — 02 reports
its registration line and this phase (or the merge) adds it. Agreed
split: 02 owns `TeamPane.swift`, 06 owns the registration array.

**Safe beside:** phases 01, 03, 04, 05 — no overlap (01 is core-only;
03/04/05 are in `windows/Sources/InfinitusWin`, a different target).

**Runs first, alongside phase 01** — neither has dependencies.

## Risks + open questions

- Each pane's real cost is whether its **model is portable**. If
  Profiles or Lock depends on Mac-only storage (keychain,
  LocalAuthentication, App Support layout), the pane is blocked on a
  core-portability change and the estimate grows. **Read all three Mac
  models before committing to the size.**
- The USER-handle quota (`SettingsPane.swift:20-27`) is a documented,
  already-hit failure. Three new panes triple the exposure.
- Growing `general` to 13 entries makes the flat sidebar worse; the
  five-group change may become necessary sooner than "out of scope"
  implies.
- Open: is Lock's function even meaningful on Windows, or does it gate
  something that has no Windows analogue? If the latter, the honest
  answer is not to ship the pane — decide from `LockModel`.
- Open: `MachineHealthTests.swift:5`'s Windows fence — does it skip
  because the signals are unavailable, or only untested? Determines
  whether Machine has content at all here.

## Estimated size

**M**, assuming the three models are portable. **L** if Profiles or Lock
needs core work first. Split per pane if it runs long — they share only
the registration array.
