#!/bin/sh
# End-to-end + performance gate (#18). Launches the DEBUG app against the
# demo engine (tools/demo-cswap: fabricated fleet, no credentials, no
# network), drives it through infinitusctl on a private control socket,
# and fails on:
#   - any command that errors, a missing window, a wrong fleet shape
#   - a switch/rotate/hold/unhold/rename/reorder that doesn't round-trip
#     into `fleets`
#   - the wall not taking over from the pop-out (and giving it back), or
#     the all-dead scenario not producing the no-candidate fleet
#   - idle CPU above IDLE_BUDGET_PCT with the pop-out open on the RPG
#     theme (the worst case: every effect armed — the 2026-09-03
#     regression idled at 39%)
#   - RSS above RSS_BUDGET_MB, or the live heap growing faster than
#     GROWTH_BUDGET_KB_MIN while idle (the 2026-09-03 per-second
#     numericText countdown grew the glyph cache ~2 MB/min for as long
#     as it ticked)
# Runs on a dev Mac (`tools/e2e.sh`) and in CI (ci.yml e2e job). The
# real app, if running, is untouched: separate socket, separate defaults
# suite (the executable name "Infinitus" from .build → domain "Infinitus",
# never com.huuloc.limitless), INFINITUS_CSWAP pinned to the demo script.
set -eu
cd "$(dirname "$0")/.."

IDLE_BUDGET_PCT="${IDLE_BUDGET_PCT:-8}"   # measured 0.3-0.5% on every theme/burn combo (2026-09-03, all effects on CA); loaded CI runners add noise, not tens of points
RSS_BUDGET_MB="${RSS_BUDGET_MB:-220}"
GROWTH_BUDGET_KB_MIN="${GROWTH_BUDGET_KB_MIN:-768}"   # idle heap growth; ~80 KB/min after the fix, 2.1 MB/min before
WINDOW_S="${WINDOW_S:-30}"   # long enough for the growth rate to mean something

BIN="$(swift build --show-bin-path)"
APP="$BIN/Infinitus"
CTL="$BIN/infinitusctl"
[ -x "$APP" ] && [ -x "$CTL" ] || { echo "build first: swift build"; exit 2; }
# A dev Mac holds the CLIProxyAPI key under the bundle id's ACL: sign the
# debug binary AS that identifier so the launch never blocks on a keychain
# prompt (ci: no identity, no key, nothing to prompt for).
ID="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')"
[ -z "$ID" ] || codesign --force --sign "$ID" --identifier com.huuloc.limitless "$APP" 2>/dev/null || true

# Its own directory: the server chmods the socket's parent to 0700.
SOCKDIR="/tmp/infinitus-e2e-$$"; mkdir -p "$SOCKDIR"
export INFINITUS_CONTROL_SOCKET="$SOCKDIR/control.sock"
export INFINITUS_CSWAP="$PWD/tools/demo-cswap"
export INFINITUS_DEMO_STATE="$SOCKDIR/demo-state.json"   # not $TMPDIR: the bundled app in mock mode shares that one
LOG="$(mktemp -t infinitus-e2e)"
DOMAIN=Infinitus   # the unbundled debug binary's defaults domain

cleanup() {
    pkill -f "$APP" 2>/dev/null || true
    # The supervised demo engine outlives its app (four orphans found
    # sleeping from earlier runs, 2026-09-03).
    pkill -f "$INFINITUS_CSWAP auto" 2>/dev/null || true
    rm -rf "$SOCKDIR"
    "$INFINITUS_CSWAP" reset >/dev/null 2>&1 || true
    # Leave the dev domain as we found it for the keys we touched.
    for k in popout_shown popover_pinned gamification_style burn_style mock_mode; do
        defaults delete "$DOMAIN" "$k" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

fail() { echo "E2E FAIL: $*"; echo "--- app log"; tail -20 "$LOG"; exit 1; }
json() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
# expect <python-bool-over-d> — the reply on stdin must satisfy it.
expect() { python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if ($1) else 1)"; }
acct() { echo "[a for a in d['fleet']['accounts'] if a['number']==$1][0]"; }
popout_visible() { "$CTL" windows | expect "any(w['visible'] and w['content']=='GlassContainerView' for w in d)"; }
wall_visible() { "$CTL" windows | expect "any(w['visible'] and 'WallRoot' in w['content'] for w in d)"; }

"$INFINITUS_CSWAP" reset >/dev/null   # pristine demo fleet: account 1 active, nothing held or aliased

# Worst-case prefs: pop-out restored on launch, RPG theme, ember burn.
defaults write "$DOMAIN" popout_shown -bool true
defaults write "$DOMAIN" popover_pinned -bool false
defaults write "$DOMAIN" gamification_style rpg
defaults write "$DOMAIN" burn_style ember
defaults write "$DOMAIN" mock_mode -bool true

"$APP" >"$LOG" 2>&1 &
APP_PID=$!
i=0
until "$CTL" status >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
        # What CI can't show otherwise: the client's error, whether the
        # socket file exists, and where the app's threads are stuck.
        echo "--- last client attempt"; "$CTL" status 2>&1 | head -3 || true
        echo "--- socket"; ls -l "$SOCKDIR" 2>&1 || true
        echo "--- app log (all)"; cat "$LOG"
        echo "--- threads"; sample "$APP_PID" 2 -file "$LOG.sample" >/dev/null 2>&1 \
            && awk '/^Call graph/,/^Total number/' "$LOG.sample" | grep -E "Thread_|^\s*\+? *[0-9]+ [^ ]" | cut -c1-150 | head -150 || true
        fail "control socket never came up"
    fi
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
popout_visible || fail "pop-out window not visible (popout_shown restore)"
echo "functional: ok ($N demo accounts, pop-out visible)"

# --- state round-trips through the demo engine ---------------------------
# Each write replies with the refreshed fleet; the change must be in it.
"$CTL" switch cswap/claude 2 | expect "d['fleet']['activeNumber']==2 and $(acct 2)['active']" || fail "switch 2 didn't take"
"$CTL" hold cswap/claude 3 | expect "$(acct 3).get('disabled')==True" || fail "hold 3 didn't take"
"$CTL" unhold cswap/claude 3 | expect "not $(acct 3).get('disabled')" || fail "unhold 3 didn't take"
"$CTL" rename cswap/claude 3 "E2E Alias" | expect "$(acct 3).get('alias')=='E2E Alias'" || fail "rename didn't take"
"$CTL" rename cswap/claude 3 "" | expect "$(acct 3).get('alias')!='E2E Alias'" || fail "rename clear didn't take"   # demo accounts carry default aliases
"$CTL" prefer cswap/claude 2 on | expect "$(acct 2).get('preferred')==True" || fail "prefer 2 didn't take"
"$CTL" prefer cswap/claude 2 off | expect "$(acct 2).get('preferred')==False" || fail "unprefer 2 didn't take"
NEXT="$("$CTL" fleets | json "d[0]['nextCandidate']")"
"$CTL" rotate cswap/claude | expect "d['fleet']['activeNumber']==$NEXT" || fail "rotate didn't land on the next candidate ($NEXT)"
ORDER="$("$CTL" fleets | json "' '.join(str(a['number']) for a in d[0]['accounts'])")"
REV="$(python3 -c "print(' '.join(reversed('$ORDER'.split())))")"
"$CTL" reorder cswap/claude $REV | expect "[a['number'] for a in d['fleet']['accounts']]==[int(x) for x in '$REV'.split()]" || fail "reorder didn't take"
"$CTL" reorder cswap/claude 1 >/dev/null 2>&1 && fail "partial reorder must be refused"
"$CTL" reorder cswap/claude $ORDER | expect "[a['number'] for a in d['fleet']['accounts']]==[int(x) for x in '$ORDER'.split()]" || fail "reorder restore didn't take"
"$CTL" switch cswap/claude 1 | expect "d['fleet']['activeNumber']==1" || fail "switch back to 1"
echo "round-trips: ok (switch, rotate, hold, unhold, rename, prefer, reorder)"
"$CTL" plan | expect "'plan' in d and (d['plan'] is None or 'steps' in d['plan'])" || fail "plan verb"
"$CTL" ignite cswap/claude 2 | expect "'fleet' in d" || fail "ignite verb"
"$CTL" forecast | expect "'forecast' in d and (d['forecast'] is None or ('basis' in d['forecast'] and 'accounts' in d['forecast']))" || fail "forecast verb"

# --- windows: the wall takes over from the pop-out and gives it back ----
"$CTL" show wall | expect "d['shown']" || fail "show wall"
sleep 2
wall_visible || fail "wall window not visible after show wall"
popout_visible && fail "pop-out still visible under the wall"
"$CTL" show wall >/dev/null || fail "show wall (toggle off)"
sleep 2
wall_visible && fail "wall still visible after toggling off"
popout_visible || fail "pop-out not restored after the wall closed"
echo "windows: ok (wall over pop-out, restored)"

# --- scenarios: all-dead (every window maxed, no candidate) --------------
"$INFINITUS_CSWAP" simulate alldead >/dev/null
"$CTL" refresh | expect "d[0].get('nextCandidate') is None and d[0].get('nextRecovery') is not None" \
    || fail "all-dead scenario not reflected in fleets"
sleep 2
popout_visible || fail "pop-out lost during all-dead"
"$INFINITUS_CSWAP" simulate off >/dev/null
"$CTL" refresh | expect "d[0].get('nextCandidate') is not None" || fail "fleet didn't recover after simulate off"
echo "scenarios: ok (all-dead and back)"

# --- control socket self-heal -------------------------------------------
# A dev instance launched without INFINITUS_CONTROL_SOCKET unlinks and
# re-binds the path; killed, it leaves an inode nobody answers and the
# bundle was unreachable for 25 minutes (2026-09-03). The app must notice
# on its next snapshot and bind again.
python3 - "$SOCKDIR/control.sock" <<'PYS'
import os, socket, sys
p = sys.argv[1]; os.unlink(p)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.bind(p); s.listen(1); s.close()  # dead inode stays
PYS
"$CTL" status >/dev/null 2>&1 && fail "a dead socket path should refuse"
i=0
until "$CTL" status >/dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -le 75 ] || fail "control socket not re-bound within a refresh interval"
    sleep 1
done
echo "control: ok (dead socket path re-bound after ${i}s)"

# --- performance --------------------------------------------------------
# Sampled AFTER the churn above so a timer left behind by a closed wall
# or a scenario swap shows up as idle cost.
sleep 10  # animations settle, launch-time caches land
A="$("$CTL" perf | json "d['cpuSeconds']")"
HEAP_A="$("$CTL" perf | json "int(d['heapBytes']/1024)")"
sleep "$WINDOW_S"
B="$("$CTL" perf | json "d['cpuSeconds']")"
HEAP_B="$("$CTL" perf | json "int(d['heapBytes']/1024)")"
RSS="$("$CTL" perf | json "int(d['rssBytes']/1048576)")"
PCT="$(python3 -c "print(round(($B-$A)/$WINDOW_S*100,1))")"
GROWTH="$(python3 -c "print(int(($HEAP_B-$HEAP_A)*60/$WINDOW_S))")"
echo "idle CPU with pop-out open (rpg + ember): ${PCT}%  rss: ${RSS} MB  heap growth: ${GROWTH} KB/min  (budgets ${IDLE_BUDGET_PCT}% / ${RSS_BUDGET_MB} MB / ${GROWTH_BUDGET_KB_MIN} KB/min)"
python3 -c "import sys; sys.exit(0 if $PCT <= $IDLE_BUDGET_PCT else 1)" || fail "idle CPU ${PCT}% over budget ${IDLE_BUDGET_PCT}%"
[ "$RSS" -le "$RSS_BUDGET_MB" ] || fail "RSS ${RSS} MB over budget ${RSS_BUDGET_MB} MB"
[ "$GROWTH" -le "$GROWTH_BUDGET_KB_MIN" ] || fail "idle heap growth ${GROWTH} KB/min over budget ${GROWTH_BUDGET_KB_MIN} KB/min"
echo "E2E PASS"
