# Limitless

Every Claude account in one menu bar — swap before you stall.

A native macOS menu bar app (Swift/SwiftUI) over the
[claude-swap](https://github.com/deathemperor/claude-swap) engine: live
5-hour / weekly / per-model gauges for every account, auto-switch status,
switch history, themes (RPG, Movie, Hades, Metal Gear, community skins),
a floating pop-out, and a live Claude Code session counter.

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
own in `~/Library/Application Support/CswapBar/themes.json`, or share one
through [`themes/`](themes/README.md) with a pull request.

## License

MIT — by [deathemperor](https://github.com/deathemperor) · [huuloc.com](https://huuloc.com)
