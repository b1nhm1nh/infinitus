# Infinitus on Omarchy (and other Waybar/Linux desktops)

The macOS app can't port (AppKit), but its Swift core does:
`infinitus-tray` is the same fleet — live gauges, themes, sentinel
notes, one-click rotate — as a Waybar `custom` module. The engine
stays behind `cswap … --json`, exactly like the app.

## Install

1. Engine: `uv tool install claude-swap` (or the PKGBUILD in
   `packaging/aur/`). Log accounts in with Claude Code, `cswap add`.
2. Binary — build once in a container (any box with Docker):

   ```sh
   docker run --rm -v "$PWD":/src -w /src swift:6.1 \
     swift build -c release -Xswiftc -static-stdlib
   install -Dm755 .build/release/infinitus-tray ~/.local/bin/infinitus-tray
   ```

   `-static-stdlib` keeps the runtime out of the way: the binary needs
   only glibc/libstdc++, present on every Arch install. (Native builds
   work too if you have a Swift toolchain.)
3. Waybar: merge `waybar-infinitus.jsonc` into your Waybar config's
   modules, append `style.css` to your Waybar stylesheet, reload.

## Use

- Bar text: active account + 5h·7d percentages (`--remaining` flips
  them to what's left).
- Tooltip: the whole fleet, themed — `--theme rpg` turns percentages
  into MP/HP, dead accounts into 💀 with a revive countdown.
  `infinitus-tray themes` lists all 15 built-ins.
- Click: rotate to the next account (`signal: 8` refreshes instantly).
- CSS classes `ok` / `warning` / `dead` / `error` mirror the active
  account's state.

Estimates shown are never billing truth; the module reads nothing of
the engine's internals.
