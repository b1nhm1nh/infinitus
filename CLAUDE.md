# Limitless — project rules

Native macOS menu bar app for the claude-swap engine. Split out of
`~/death/claude-swap/swift/CswapBar` on 2026-08-29 with history.

## Non-negotiables
- **Everything is Swift; the engine is fully isolated.** Every engine
  touchpoint is a `cswap … --json` subprocess (CswapCore/CswapCLI.swift).
  Never read engine internals (`~/.claude-swap-backup/*`). Reading
  `~/.claude/settings.json` (Claude Code's file) is fine.
- **Bundle id stays `io.github.claude-swap.CswapBar.g2`** until the id
  change is done as one deliberate step (Notification Center and login-item
  grants key on it; the last casual change cost a day of ControlCenter-ban
  debugging). Same for the App Support path `CswapBar/`.
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
- usernoted refuses dev-cert builds without a provisioning profile;
  notifications fall back to osascript (working mode, not an error).
- SwiftUI Grid: spanning cells span the widest row's real column count;
  placeholders need `.frame(maxWidth: .infinity)` +
  `.gridCellUnsizedAxes(.horizontal)`.

## Build / run / test
`./make-app.sh && open Limitless.app` · `swift test` · `./dev.sh` (entr)
· `./run-unbundled.sh` (menu bar wedge workaround).
