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

## Omarchy 4+ (Quickshell bar)

Newer Omarchy replaced Waybar with a Quickshell shell. The same
`infinitus-tray` binary drives a native bar plugin instead:

1. Copy `quickshell-plugin/infinitus/` to `~/.config/omarchy/plugins/infinitus/`
   (the shell hot-reloads local plugins).
2. Add `{ "id": "infinitus.fleet" }` to `bar.layout.right` in
   `~/.config/omarchy/shell.json` — a plugin is enabled by being
   referenced there.
3. The widget execs `~/.local/bin/infinitus-tray` — install the binary
   (or a wrapper) at that path. Theme id and refresh interval live in
   the widget's settings (`barWidget.schema`).

Building natively on Arch instead of the Docker route: the official
ubuntu24.04 toolchain tarball runs fine with three symlink shims
(`libncurses.so.6` and `libtinfo.so.6` -> `libncursesw.so.6`,
`libxml2.so.2` -> `libxml2.so.16`) on `LD_LIBRARY_PATH`; the built
binary needs the toolchain's `usr/lib/swift/linux` on its runtime
`LD_LIBRARY_PATH` too (or `-static-stdlib`).
