#!/bin/sh
# Forwards the hook payload on stdin to the Infinitus Mac app (#79).
# Never blocks a session: exit 0 whatever happens, nothing on stdout.
ctl="${INFINITUS_CTL:-$(command -v infinitusctl 2>/dev/null)}"
[ -x "$ctl" ] || ctl=/Applications/Infinitus.app/Contents/MacOS/infinitusctl
[ -x "$ctl" ] || exit 0
payload=$(cat)
# One retry: the app answers one control command at a time, and two
# sessions' hooks can land together.
printf '%s' "$payload" | "$ctl" event >/dev/null 2>&1 \
  || { sleep 1; printf '%s' "$payload" | "$ctl" event >/dev/null 2>&1; }
exit 0
