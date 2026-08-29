#!/bin/sh
# Dev loop: rebuild the bundle and relaunch CswapBar whenever a source
# file changes. Closest thing to hot reload that fits headless CLI dev —
# make-app.sh keeps the same bundle path, so notification/login grants
# survive each relaunch.
cd "$(dirname "$0")" || exit 1
command -v watchexec >/dev/null || { echo "needs watchexec (brew install watchexec)"; exit 1; }
exec watchexec --watch Sources --exts swift --debounce 500ms -- \
    sh -c './make-app.sh && { pkill -x CswapBar; open CswapBar.app; }'
