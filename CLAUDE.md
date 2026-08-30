# Limitless — project rules

Native macOS menu bar app for the claude-swap engine. Split out of
`~/death/claude-swap/swift/CswapBar` on 2026-08-29 with history.

## Non-negotiables
- **Everything is Swift; the engine is fully isolated.** Every engine
  touchpoint is a `cswap … --json` subprocess (CswapCore/CswapCLI.swift).
  Never read engine internals (`~/.claude-swap-backup/*`). Reading
  `~/.claude/settings.json` (Claude Code's file) is fine.
- **Bundle id is `com.huuloc.limitless`** — the one deliberate change,
  done 2026-08-30 (user-approved). App Support moved to `Limitless/`
  (copy-migration from `CswapBar/`; legacy dir left for rollback).
  Notification Center and login-item grants key on the id and must be
  re-granted once under it. Never change the id casually again — the
  2026-08-29 casual change cost a day of ControlCenter-ban debugging.
- **Push nothing to any remote** unless explicitly asked. Commit locally.
- Secrets (webhook URLs, bot tokens) travel over stdin, never argv; shown
  masked only. Usage-cost figures are estimates, never billing truth.
- Surgical changes; match existing style; no speculative abstractions.

## Hard-won facts
- NSPopover measures content once; wholesale content-shape swaps must go
  through `withAnimation` so it re-measures live. Never close/reopen.
- macOS ignores Dynamic Type — popup scaling is `PopupScale`
  (fixedSize → measure → scaleEffect + matching frame). Measuring without
  `fixedSize` feeds the scaled width back in and runs away ×scale.
- The pop-out window must NOT let NSHostingView size it (crash on
  unbounded ideal width); PinnedRoot reports its fixedSize geometry and
  `fitPinned` applies it.
- macOS 26 ControlCenter can stop adopting new bundled apps' status items
  after rapid relaunch churn — only a logout clears it; `run-unbundled.sh`
  is the workaround. Don't run the dev loop's kill/reopen cycle for hours.
- NSPopover windows refuse CABackdropLayer at every level (renders a
  black slab; probed 2026-08-30) — the anchored popup is therefore a
  borderless non-activating NSPanel. CABackdropLayer + CAFilter
  gaussianBlur in a plain window is the only tunable-blur glass.
- NSGlassEffectView does NOT deactivate when its window resigns key —
  the "goes solid unfocused" repro was the probe window being occluded.
  Never reintroduce a focus-swap around it; glass runs in all states.
- usernoted refuses dev-cert builds without a provisioning profile;
  notifications fall back to osascript (working mode, not an error).
- SwiftUI Grid: spanning cells span the widest row's real column count;
  placeholders need `.frame(maxWidth: .infinity)` +
  `.gridCellUnsizedAxes(.horizontal)`.

## Build / run / test
`./make-app.sh && open Limitless.app` · `swift test` · `./dev.sh` (entr)
· `./run-unbundled.sh` (menu bar wedge workaround).
