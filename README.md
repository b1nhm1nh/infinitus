# Limitless

Every Claude account in one menu bar — swap before you stall.

A native macOS menu bar app (Swift/SwiftUI) over the
[claude-swap](https://github.com/deathemperor/claude-swap) engine.

## Features

- **Menu bar usage** — active account name plus 5h/weekly percentages
  in the bar (used or remaining, your pick), glyph-only mode too.
- **Every account at a glance** — live 5-hour / weekly / per-model
  gauges for the whole fleet, pace markers when a window is burning
  faster than time passes, reset countdowns, dead rows with the cause.
- **Auto-switch aware** — the next-candidate pick, switch history,
  a celebration sweep on every switch (and a death beat when an
  account runs out).
- **Themes** — RPG (HP/MP + gold), Movie, Hades, Metal Gear, AI
  Agentic, Classic SWE, Sci-Fi, Wild West, Cyberpunk, Gothic, or plain
  numbers; a Themes settings pane with card grid, your own skins via
  `themes.json`, and a community gallery.
- **Glass popup** — real backdrop blur in every focus state, with a
  transparency dial; a launch intro (slides, bar fill-up, title
  flourish — all tunable in the debug pane).
- **Right-click menu** on the bar icon — themes, rotate, refresh,
  pin, pop out, settings, restart, quit; pairs with a setting that
  hides the popup's buttons but keeps the status chips.
- **Sessions & status chips** — live Claude Code session counter
  (busy/idle breakdown), engine status, auto-mode indicator.
- **Cost estimates** — 7-day per-account API-list-price estimates
  (estimates, never billing truth).
- **iCloud settings sync** + file export/import (never credentials).
- **Push notifications** — switch/limit events to Slack, Discord,
  Telegram or a webhook; secrets travel over stdin, shown masked.
- **Pop-out window, compact mode, stacked/wide layouts, popup
  scaling** — and a first-run card that installs the engine for you.

## Requirements

- macOS 14+
- the `cswap` CLI on PATH (`uv tool install claude-swap` / `pipx install claude-swap`)

## Build & run

```sh
./make-app.sh && open Limitless.app
```

`swift test` runs the CswapCore unit tests. `dev.sh` is a rebuild-on-save
loop (needs `entr`). `run-unbundled.sh` runs the executable outside the
bundle — a workaround for a login session whose menu bar stops adopting
new bundled apps (see the script header).

## Architecture rule

Everything is Swift; the engine stays fully isolated behind
`cswap … --json` subprocesses. The app never reads engine internals from
disk.

## Themes

Built-in row themes live in `Sources/CswapCore/RowTheme.swift`; add your
own in `~/Library/Application Support/Limitless/themes.json`, or share one
through [`themes/`](themes/README.md) with a pull request.

## License

MIT — by [deathemperor](https://github.com/deathemperor) · [huuloc.com](https://huuloc.com)
