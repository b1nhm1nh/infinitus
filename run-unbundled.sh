#!/bin/sh
# Workaround for a wedged ControlCenter login session (seen 2026-08-29 on
# macOS 26 after dozens of rapid relaunches): status items from newly
# launched BUNDLED apps are never adopted into the menu bar until the user
# logs out, while an unbundled process renders immediately. This runs the
# built executable outside CswapBar.app, ad-hoc re-signed (the bundle's
# signature is invalid standalone — AMFI kills the raw copy).
#
# Costs while running this way: prefs live in the "Limitless-unbundled"
# domain (seeded from the app's on first use), Notification Center is
# unavailable (osascript fallback, same as dev builds), and the login-item
# toggle is disabled. Log out/in once and go back to `open CswapBar.app`.
set -eu
cd "$(dirname "$0")"
OUT="$HOME/Library/Application Support/CswapBar/Limitless-unbundled"
mkdir -p "$(dirname "$OUT")"
pkill -x CswapBar 2>/dev/null || true
pkill -x Limitless-unbundled 2>/dev/null || true
sleep 0.5
cp CswapBar.app/Contents/MacOS/CswapBar "$OUT"
codesign --force --sign - "$OUT" 2>/dev/null
if ! defaults read Limitless-unbundled >/dev/null 2>&1; then
    defaults export io.github.claude-swap.CswapBar.g2 - 2>/dev/null \
        | defaults import Limitless-unbundled - 2>/dev/null || true
fi
nohup "$OUT" >/dev/null 2>&1 &
echo "launched unbundled Limitless (pid $!)"
