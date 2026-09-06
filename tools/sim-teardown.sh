#!/bin/bash
# Shuts the iOS Simulator down once nobody is using it (user 2026-09-06:
# "when agents finish using the sim shut it down"). Wired as a Claude Code
# SubagentStop / Stop hook in .claude/settings.json, so it runs after every
# agent and every turn; it is a no-op unless a simulator is booted, and it
# leaves a simulator alone while any xcodebuild / simctl install / launch is
# still running (another agent may be mid-build). A booted simulator holds
# a few hundred MB and its own process tree — on a Mac already swapping
# through a team publish that is not free.
set -u
command -v xcrun >/dev/null 2>&1 || exit 0
xcrun simctl list devices booted 2>/dev/null | grep -q '(Booted)' || exit 0
if pgrep -f 'xcodebuild|simctl (install|launch|boot)|xctest' >/dev/null 2>&1; then
    exit 0
fi
# Detached: the hook must return at once; the shutdown itself takes seconds.
(
    xcrun simctl shutdown all >/dev/null 2>&1
    osascript -e 'tell application "Simulator" to quit' >/dev/null 2>&1
) >/dev/null 2>&1 &
exit 0
