# Phase 07 — a contained DirectComposition effects spike (optional, last)

## Goal

Find out whether Windows can host compositor-driven motion the way the
Mac's `LayerEffect` does — animation that runs in the compositor with no
per-frame work in-process. One host, one effect, budget-gated, with a
stated fallback. **Build the perf gate first**, because Windows has none
and this is the one phase that can regress idle CPU.

## Non-goals

- Not a port of the Mac's effect suite (there are ~18 of them). One
  effect, to answer one question.
- No repaint timer, under any circumstance. CLAUDE.md's rule is the
  whole reason this phase is shaped as a spike rather than a feature.
- Not the Animations debug pane (phase 06 defers it here; it only makes
  sense if this spike succeeds).
- Optional and last. A clean "no" is a successful outcome.

## Current state

### What the Mac does, and why

`Sources/InfinitusUI/LayerEffect.swift` — `:9-21` the rationale
(CAAnimations run in the render server; the app does **no** per-frame
work; SwiftUI's TimelineView/`repeatForever` costs ~7 ms per frame
commit — "RPG popup idled at 40% CPU with the pop-out open (#18,
2026-09-03)"); `:22-24` the entire API,
`struct LayerEffect { let install: (CALayer, CGRect) -> Void }`; `:26`
`LayerEffectHost`; `:39-50` `installIfNeeded()`, rebuilding sublayers
once per bounds change inside a `CATransaction` with actions disabled;
`:52-57` `wantsLayer = true`, `layerContentsRedrawPolicy = .never`;
`:68` `hitTest → nil` (effects never take input); `:114-128`
`CABasicAnimation.loop`, `:145-157` `CAKeyframeAnimation.cycle`.

Candidate effects to port, per the brief:
- **Burn overlay** — `Sources/InfinitusUI/BurnEffect.swift:20`
  `BurnOverlay`, `LayerEffect {` at `:35`, heat fill + marquee (doc
  `:11-13`); sparks are a `CAEmitterLayer`, `:110` `sparks(...)`,
  emitter built `:134`, used `:181`, `:225`.
- **Switch flash** — `Sources/InfinitusUI/Effects.swift:6`
  `SwitchFlash: ViewModifier`, public entry `switchFlash(_:color:)`
  `:91`; tick source `Sources/Infinitus/AppModel.swift:57-59` and
  `FleetState.swift:25`.

Note the Mac's own taxonomy: not everything is a LayerEffect.
`BurnEffect.swift:333` `KillBurst` is a deliberate one-shot ~0.9 s
TimelineView (`:337-341` explains why that is acceptable), and the
HP-drop zoom (`GaugeBar.swift:297-300`, `:303-318`) is transient SwiftUI.
**Only continuous motion must be compositor-driven** — that distinction
is the rule, and it is what makes a one-shot flash a much easier target
than a burn overlay.

### The Windows window stack — the blocker

Every window is a plain redirected-surface HWND painted with GDI:

- Fleet panel: `windows/Sources/InfinitusTrayWin/FleetWindow.swift:431-443`
  `registerClassIfNeeded()` (`WNDCLASSW` + `RegisterClassW` at `:443`,
  `hbrBackground = CreateSolidBrush(bg)` `:439`); `:320` style
  `WS_OVERLAPPED|WS_CAPTION|WS_SYSMENU|WS_MINIMIZEBOX`;
  **`:321-324` `CreateWindowExW(0, …)` — `dwExStyle` is `0`**;
  `:493-496` `WM_ERASEBKGND → 1` (suppressed); `:498-500` `WM_PAINT →
  paint`; **`:625-643` `paint()` — GDI double buffer: `BeginPaint`
  `:627`, `CreateCompatibleDC` `:634`, `CreateCompatibleBitmap` `:635`,
  `SelectObject` `:637`, `BitBlt(SRCCOPY)` `:639`** (comment `:632-633`:
  "drawing rows straight to the window tears visibly on a resize");
  `:645-657` `fill`/`draw`/`drawWrapped`.
- Settings shell: `SettingsShell.swift:163-178` (`WNDCLASSEXW` +
  `RegisterClassExW` `:177`), **`:137-150` `CreateWindowExW(0, …,
  WS_OVERLAPPEDWINDOW|WS_CLIPCHILDREN, …)`**, paint `:523-531`, `:774`
  `WM_PAINT`, `:779` `WM_ERASEBKGND`.
- Pane host: `SettingsPane.swift:148-357` `PaneHost`, **`:186-198`
  `CreateWindowExW(0, …, WS_CHILD|WS_CLIPCHILDREN|WS_VSCROLL, …)`**;
  `:227`, `:255`, `:311` `ScrollWindowEx(SW_SCROLLCHILDREN|SW_INVALIDATE)`
  — **panes are stacks of real child HWNDs that scroll by blit**;
  `:266-356` `hostWndProc` has **no `WM_PAINT` case** (falls to
  `DefWindowProcW` `:354`); `:365-583` `PaneControls`, every widget a
  child HWND; `:485-497` `canvas(...)`, an `SS_OWNERDRAW` static — the
  only custom-draw surface a pane gets.
- Tray host window: `main.swift:691` `CreateWindowExW(0, …)`, hidden
  message-only, zero size; `:701` `Shell_NotifyIconW(NIM_ADD)`;
  `:44-45` `refreshMilliseconds: UINT = 5000` — "the one knob that
  decides idle cost (CLAUDE.md: keep it near zero)".
- `TrayIcon.swift` — no window code at all; pure GDI icon synthesis
  (`CreateDIBSection` `:29`, per-pixel ring `:42-49`,
  `CreateIconIndirect` `:64`).

**`dwExStyle == 0` everywhere.** No `WS_EX_LAYERED`, no
`WS_EX_NOREDIRECTIONBITMAP`, no `WS_EX_COMPOSITED` anywhere in the repo.
So GDI content and a DComp visual **cannot** be composited on the same
redirected surface — a DComp visual tree needs either
`WS_EX_NOREDIRECTIONBITMAP` on a new child/popup HWND, or a separate
composition-target window. That is the central technical fact of this
phase.

### No COM precedent at all

Grep over `windows/` for
`Direct2D|D2D|DComp|DirectComposition|DWrite|ID2D1|IDXGI|D3D11`:
**zero matches, comments included.** Grep for
`IUnknown|CoCreateInstance|CoInitialize|GUID|IID_|QueryInterface`:
**zero matches** — no `CLSCTX`, no `IWIC*`, no vtable shims.

The closest existing Win32 use is a **flat C API**:
`windows/Sources/InfinitusTrayWin/WinDark.swift:112` and `:116`
`DwmSetWindowAttribute(...)`. Security-descriptor code
(`WinSecret.swift:68-77`, `ControlServer.swift:104-113`,
`WinPairingStore.swift:56-65`) is likewise flat Win32, not COM.

Linked libraries for the tray: `Package.swift:104-108` — `user32,
shell32, gdi32, comctl32, ws2_32, iphlpapi, dwmapi, crypt32, comdlg32`.
**No `d2d1`, `dwrite`, `dcomp`, `dxgi`, `d3d11`, `ole32`/`combase`.**
So this phase requires the project's **first COM vtable interop** plus
new `.linkedLibrary` entries. (`windows/README.md`'s "Not Yet
Implemented" §1 lists WIC thumbnails — `IWICImagingFactory` — as the
other future COM dependency, so the interop pattern would be reused.)

### The existing design decision this phase reopens

`windows/README.md:696-703` states it plainly: burn overlays, HP-drop
zooms and intro choreography are deliberately **not** copied — "GDI has
no equivalent compositor, so imitating them would need a repaint timer —
the exact thing that rule forbids." Pace is shown statically instead.
Measured idle with the panel open: **0.13% CPU, 30 MB** (`:703`). Also
`FleetWindow.swift:19-23` and `:951`, and `main.swift:515-516`, cite the
rule in code.

This phase's premise is that DirectComposition *is* the equivalent
compositor, which if true makes that paragraph out of date rather than
wrong.

### Windows has no perf gate — the prerequisite

- Mac/CI gate: `tools/e2e.sh:2-21` (header, failure conditions `:11-17`
  — "the 2026-09-03 regression idled at 39%"), `:26`
  `IDLE_BUDGET_PCT=8`, `:27` `RSS_BUDGET_MB=220`, `:28`
  `GROWTH_BUDGET_KB_MIN=768`, `:29` `WINDOW_S=30`; `:246-251` the
  all-dead CPU gate; `:403-418` the main pass — `$CTL perf` twice around
  `sleep $WINDOW_S` reading `cpuSeconds`/`heapBytes`/`rssBytes`, then
  `:416` idle-CPU, `:417` RSS, `:418` heap-growth gates. Backing route:
  `Sources/Infinitus/ControlServer.swift:544` `case "perf":`
  (`getrusage` `:545-548`, `mach_task_basic_info` `:549-555`,
  `heapBytes` `:571`); shape at
  `Sources/InfinitusCore/ControlProtocol.swift:210-212`. CI:
  `.github/workflows/ci.yml:29-32`, `:50`.
- **Windows: nothing.** `windows/ci.ps1:1-27` is build + build + `swift
  test`, no measurement. `windows/smoke.ps1` is functional only —
  grepping it for `perf|idle|cpu|heapBytes|WorkingSet|Get-Process`
  returns nothing. `.github/workflows/ci.yml:88-105` — the `windows` job
  is `continue-on-error: true` (`:95`, comment `:85-86` "Non-blocking
  until proven on real runners") and runs only two builds and
  `swift test`. **`windows/Sources/InfinitusWin/ControlServer.swift:210-322`
  has no `"perf"` case** — the daemon cannot answer the query `e2e.sh`
  depends on. Grepping `windows/Sources` for
  `heapBytes|rssBytes|cpuSeconds|GetProcessMemoryInfo|WorkingSet`:
  no matches.

The one published Windows number (0.13% / 30 MB) is hand-measured prose,
not an asserted budget. **Any DComp work would land with no automated
regression detection on the platform it targets.**

## Design

### Step 0 (mandatory, and valuable alone) — the Windows perf gate

Do this first and merge it independently of the spike's outcome.

- Add a `"perf"` case to
  `windows/Sources/InfinitusWin/ControlServer.swift`'s route table
  (`:210-322`), answering the same shape as
  `ControlProtocol.swift:210-212`:
  `{cpuSeconds, rssBytes, heapBytes, threads, uptimeSeconds}`. Windows
  primitives: `GetProcessTimes` (user+kernel → `cpuSeconds`),
  `GetProcessMemoryInfo` (`PROCESS_MEMORY_COUNTERS.WorkingSetSize` →
  `rssBytes`, `PrivateUsage` a reasonable `heapBytes` stand-in),
  `GetProcessHandleCount`/thread enumeration. Flat Win32 — no COM.
- **Measure the tray, not just the daemon.** The effects live in
  `infinitus-tray-win`, and the panel is what idles. The tray has no
  control socket; the cheapest honest gate is a PowerShell sampler in
  `windows/smoke.ps1` (or a new `windows/perf.ps1`) using
  `Get-Process` twice around a 15-30 s sleep — the same two-samples
  method `tools/e2e.sh:407-412` uses, and the same interval CLAUDE.md
  prescribes (`infinitusctl perf` twice, 15 s apart).
- Wire it into `windows/ci.ps1` with budgets. Since the CI windows job
  is `continue-on-error: true`, the gate is advisory there — so it must
  also be runnable locally and recorded in the phase's acceptance.
- **Also add a USER/GDI handle check.** `SettingsPane.swift:20-27`
  documents the 10k USER-handle quota being exhausted during one window
  drag; a DComp visual tree per pane is exactly the kind of thing that
  leaks handles. `GetGuiResources` gives the count.

### Step 1 — the spike, scoped hard

**Pick the switch flash, not the burn overlay.** Reasons: the burn
overlay is continuous motion *plus* a `CAEmitterLayer` particle system
(`BurnEffect.swift:110-134`), i.e. two unsolved problems; the switch
flash (`Effects.swift:6`, `:91`) is a short opacity/color transition
driven by an existing tick (`AppModel.swift:57-59`). A one-shot flash
answers the question "can a compositor animation run over this window at
all" with a fraction of the surface area, and it is the effect whose
absence is most visible in the panel (an account switch currently has no
visual acknowledgement).

Target surface: the **fleet panel** (`FleetWindow.swift`), not a settings
pane. The panel is one window with one `WM_PAINT`
(`FleetWindow.swift:498-500`, `:625-643`), whereas a pane is a stack of
child HWNDs scrolled by `ScrollWindowEx`
(`SettingsPane.swift:227`, `:255`, `:311`) — layering a composition
target under scrolling child windows is a much worse first experiment.

Approach, in order of preference:

1. **A separate composition child HWND** created with
   `WS_EX_NOREDIRECTIONBITMAP`, parented into the panel, carrying a
   `DCompositionCreateDevice` visual tree with an animation
   (`IDCompositionAnimation`) — the closest structural analogue to
   `LayerEffectHost` (`LayerEffect.swift:26`, `hitTest → nil` at `:68`
   maps to `WS_EX_TRANSPARENT`/no hit-testing). GDI keeps painting the
   panel; the effect window composites above it.
2. If child-HWND layering fights the parent's `BitBlt`
   (`FleetWindow.swift:639`) or the DWM redirection, fall back to a
   **separate always-on-top popup** positioned over the panel — uglier,
   and it will misbehave on move/resize, but it isolates the question.

Keep it behind a flag, off by default, so the panel's shipped behaviour
is untouched while the spike is evaluated.

### Step 2 — the explicit fallback

**If the win32 surface fights DComp layering, the answer is no and the
phase ends there.** The fallback is not "use a timer" — it is what
`windows/README.md:696-703` already ships: static presentation. A
one-shot, bounded, non-repeating GDI repaint (a flash that paints ~10
frames over 300 ms and then stops) is *arguably* within the rule, since
the rule targets **continuous** motion and the Mac itself allows a
bounded one-shot (`BurnEffect.swift:337-341`, `KillBurst`). If the spike
fails, that is the compromise worth measuring — with the gate from
Step 0 proving it costs nothing at idle, because it does not run at
idle.

State the outcome either way in `windows/README.md`, replacing the "GDI
has no equivalent compositor" paragraph with what was actually learned.

## Test plan

- `swift build --product infinitus-tray-win`, and separately
  `--product infinitus-win` for the perf route (one `--product` per
  invocation, CLAUDE.md). `swift test` under `. .\windows\env.ps1`,
  never setting `INCLUDE`/`LIB` (`windows/env.ps1:9-12`) — note that a
  new `.linkedLibrary` for `dcomp`/`d2d1` is a `Package.swift` change
  and the manifest itself must still compile under that constraint.
- Perf route: unit-test the *shape* of the `perf` reply in
  `windows/Tests/InfinitusWinTests/ControlServerTests.swift` (the suite
  exists); the values are environmental and cannot be asserted.
- **The spike's real test is the gate, not a unit test.** Acceptance is
  two `Get-Process` samples 15-30 s apart with the panel open and the
  effect enabled, compared against the same with it disabled, plus the
  handle count. `tools/e2e.sh:26-29` supplies the budget precedent
  (8% idle CPU, 220 MB RSS) but the Windows baseline is far lower —
  0.13% / 30 MB (`windows/README.md:703`) — so **the budget should be
  set from the measured Windows baseline, not inherited from the Mac's.**
- No `XCTSkip` concerns: the whole `windows/` suite only builds on
  Windows. If DComp is unavailable on a runner, the spike code must be
  flag-off by default so nothing skips or fails.

## Acceptance criteria

- [ ] `infinitus-win` answers a `perf` control query with
      `{cpuSeconds, rssBytes, heapBytes, threads, uptimeSeconds}`.
- [ ] A Windows perf sampler exists, measures the **tray** with the
      panel open, checks idle CPU, working set, growth and USER/GDI
      handles, and is wired into `windows/ci.ps1`.
- [ ] Budgets are set from the measured Windows baseline, and the
      current 0.13% / 30 MB figure is reproduced by the new gate.
- [ ] One effect (switch flash) either runs as a compositor animation
      over the panel with **idle CPU indistinguishable from baseline**,
      or the phase records why layering failed.
- [ ] With the flag off, the panel is byte-identical in behaviour and
      cost to today.
- [ ] No repaint timer ships. If the fallback is a bounded one-shot, it
      provably does not run at idle.
- [ ] `windows/README.md`'s "GDI has no equivalent compositor"
      paragraph is replaced with the measured finding.
- [ ] No handle-count growth across repeated panel open/close and
      resize.

## Parallelization notes

**Owns exclusively:** the new perf sampler script
(`windows/perf.ps1` or the perf section of `windows/smoke.ps1`), the
new DComp host source under
`windows/Sources/InfinitusTrayWin/`, and the `perf` case in
`windows/Sources/InfinitusWin/ControlServer.swift`.

**Edits (shared):** `windows/ci.ps1` (nobody else touches it),
`Package.swift` (new `.linkedLibrary` entries at `:104-108` — no other
phase edits the manifest), and
`windows/Sources/InfinitusTrayWin/FleetWindow.swift` (the panel host).

**Conflicts with phase 03** on `ControlServer.swift` — 03 touches the
delivery lane at `:275-285`, this phase adds a route case at `:210-322`.
Different regions, but coordinate; 03 first.

**Safe beside:** phases 01, 02, 04, 06 — no overlap. Phase 06 owns
`SettingsShell.swift` and the panes; this phase deliberately targets
`FleetWindow.swift` instead, which keeps them apart.

**Runs last.** Step 0 (the perf gate) is the exception and can run any
time — it is independently valuable and unblocks honest measurement for
every other phase.

## Risks + open questions

- **The whole premise may not survive contact.** Every window is
  `dwExStyle == 0` with GDI `BitBlt` painting; DComp needs a
  non-redirected surface. That is the fact most likely to end the
  phase, which is why it is scoped as a spike with a stated fallback.
- **First COM interop in the codebase.** No `IUnknown`, no
  `QueryInterface`, no vtable shim exists to copy. Swift's Windows COM
  ergonomics are manual (vtable structs, `unsafeBitCast`), so even a
  successful spike lands a new category of code the repo has no
  precedent for maintaining.
- Shipping a compositor animation with **no automated idle-CPU gate**
  would be the exact 2026-09-03 mistake on a new platform. Step 0 is
  therefore not optional, and it is why Step 0 merges separately.
- DComp interacts with DWM: on a remote desktop session, or with
  composition disabled, the visual may not render. The panel must
  degrade to today's static presentation, not to a blank rectangle.
- Open: does the Swift `WinSDK` module expose the DComp interfaces at
  all, or must they be hand-declared? Same unknown as phase 05's
  `CreatePseudoConsole`. Answer this in the first hour — it may end the
  phase cheaply.
- Open: is a switch flash worth this much machinery? If the answer to
  the spike is "yes but it costs a COM layer", the honest follow-up
  question is whether any Windows user asked for the motion.

## Estimated size

**Step 0: S** (and worth doing regardless). **Spike: M**, with a real
chance of ending early in either direction. Porting the full effect
suite afterwards would be **L** and is not proposed.
