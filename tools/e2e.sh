#!/bin/sh
# End-to-end + performance gate (#18). Launches the DEBUG app against the
# demo engine (tools/demo-cswap: fabricated fleet, no credentials, no
# network), drives it through infinitusctl on a private control socket,
# and fails on:
#   - any command that errors, a missing window, a wrong fleet shape
#   - idle CPU above IDLE_BUDGET_PCT with the pop-out open on the RPG
#     theme (the worst case: every effect armed — the 2026-09-03
#     regression idled at 39%)
#   - RSS above RSS_BUDGET_MB
# Runs on a dev Mac (`tools/e2e.sh`) and in CI (ci.yml e2e job). The
# real app, if running, is untouched: separate socket, separate defaults
# suite (the executable name "Infinitus" from .build → domain "Infinitus",
# never com.huuloc.limitless), INFINITUS_CSWAP pinned to the demo script.
set -eu
cd "$(dirname "$0")/.."

IDLE_BUDGET_PCT="${IDLE_BUDGET_PCT:-8}"   # measured 0.3-0.5% on every theme/burn combo (2026-09-03, all effects on CA); loaded CI runners add noise, not tens of points
RSS_BUDGET_MB="${RSS_BUDGET_MB:-220}"
WINDOW_S="${WINDOW_S:-15}"

BIN="$(swift build --show-bin-path)"
APP="$BIN/Infinitus"
CTL="$BIN/infinitusctl"
[ -x "$APP" ] && [ -x "$CTL" ] || { echo "build first: swift build --product Infinitus --product infinitusctl"; exit 2; }
# A dev Mac holds the CLIProxyAPI key under the bundle id's ACL: sign the
# debug binary AS that identifier so the launch never blocks on a keychain
# prompt (ci: no identity, no key, nothing to prompt for).
ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')"
[ -z "$ID" ] || codesign --force --sign "$ID" --identifier com.huuloc.limitless "$APP" 2>/dev/null || true

export INFINITUS_CONTROL_SOCKET="/tmp/infinitus-e2e-$$.sock"
export INFINITUS_CSWAP="$PWD/tools/demo-cswap"
LOG="$(mktemp -t infinitus-e2e)"
DOMAIN=Infinitus   # the unbundled debug binary's defaults domain

cleanup() {
    pkill -f "$APP" 2>/dev/null || true
    rm -f "$INFINITUS_CONTROL_SOCKET"
    # Leave the dev domain as we found it for the keys we touched.
    for k in popout_shown popover_pinned gamification_style burn_style mock_mode; do
        defaults delete "$DOMAIN" "$k" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

fail() { echo "E2E FAIL: $*"; echo "--- app log"; tail -20 "$LOG"; exit 1; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

# Worst-case prefs: pop-out restored on launch, RPG theme, ember burn.
defaults write "$DOMAIN" popout_shown -bool true
defaults write "$DOMAIN" popover_pinned -bool false
defaults write "$DOMAIN" gamification_style rpg
defaults write "$DOMAIN" burn_style ember
defaults write "$DOMAIN" mock_mode -bool true

"$APP" >"$LOG" 2>&1 &
i=0
until "$CTL" status >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 60 ] || fail "control socket never came up"
    sleep 1
done
echo "app up after ${i}s"

# --- functional ---------------------------------------------------------
"$CTL" manifest | json "len(d['commands'])" | grep -qE '^[1-9][0-9]*$' || fail "manifest empty"
"$CTL" status | json "d['engines']['cswap']['registered']" | grep -q True || fail "cswap not registered"
sleep 4   # first demo snapshot
N="$("$CTL" fleets | json "sum(len(f['accounts']) for f in d)")"
[ "$N" -ge 5 ] || fail "expected the demo fleet (>=5 accounts), got $N"
"$CTL" fleets | json "d[0]['key']" | grep -q '^cswap/claude$' || fail "primary fleet key"
"$CTL" remove cswap/claude 1 >/dev/null 2>&1 && fail "remove without --yes must be refused"
"$CTL" switch nope/x 1 >/dev/null 2>&1 && fail "unknown fleet must be refused"
"$CTL" prefer cswap/claude 2 on | json "'alpha' in ' '.join(d['preferred']) or d['preferred']" >/dev/null || fail "prefer"
"$CTL" prefer cswap/claude 2 off >/dev/null || fail "unprefer"
"$CTL" windows | json "any(w['visible'] and w['content']=='GlassContainerView' for w in d)" | grep -q True \
    || fail "pop-out window not visible (popout_shown restore)"
echo "functional: ok ($N demo accounts, pop-out visible)"

# --- performance --------------------------------------------------------
sleep 6   # intro animations settle
A="$("$CTL" perf | json "d['cpuSeconds']")"
sleep "$WINDOW_S"
B="$("$CTL" perf | json "d['cpuSeconds']")"
RSS="$("$CTL" perf | json "int(d['rssBytes']/1048576)")"
PCT="$(python3 -c "print(round(($B-$A)/$WINDOW_S*100,1))")"
echo "idle CPU with pop-out open (rpg + ember): ${PCT}%  rss: ${RSS} MB  (budgets ${IDLE_BUDGET_PCT}% / ${RSS_BUDGET_MB} MB)"
python3 -c "import sys; sys.exit(0 if $PCT <= $IDLE_BUDGET_PCT else 1)" || fail "idle CPU ${PCT}% over budget ${IDLE_BUDGET_PCT}%"
[ "$RSS" -le "$RSS_BUDGET_MB" ] || fail "RSS ${RSS} MB over budget ${RSS_BUDGET_MB} MB"
echo "E2E PASS"
