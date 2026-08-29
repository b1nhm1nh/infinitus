#!/bin/sh
# Dev loop: rebuild the bundle and relaunch CswapBar whenever a source
# file changes. Closest thing to hot reload that fits headless CLI dev —
# make-app.sh keeps the same bundle path, so notification/login grants
# survive each relaunch. entr, not watchexec: watchexec 2.7 fails to
# spawn anything on this machine ("No such file or directory").
cd "$(dirname "$0")" || exit 1
command -v entr >/dev/null || { echo "needs entr (brew install entr)"; exit 1; }
while :; do
    # -d: exit when a NEW file appears so the outer loop re-lists;
    # -n: no TTY (runs fine in the background).
    find Sources -name '*.swift' | entr -n -d sh -c \
        './make-app.sh && { pkill -x Limitless; open Limitless.app; } && echo "== relaunched $(date +%H:%M:%S)"'
done
