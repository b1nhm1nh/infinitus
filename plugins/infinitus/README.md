# Infinitus plugin for Claude Code

Two hooks, one script: `Notification` and `Stop` pipe their payload to
`infinitusctl event`. The Mac app pushes a permission or question to your
phone the moment it appears (the poll alone takes up to a minute) and
refreshes the fleet when a turn ends. Nothing here can block a session —
the script exits 0 whether the app is running or not.

An MCP server (`infinitusctl mcp`, wired by `.mcp.json`) gives every
session three tools — `fleet_status`, `list_sessions`, `session_message`
(send text to another live session by pid or name) — and the `/infinitus:status`
skill answers "how are the accounts doing" in three lines from them.

Install: `infinitusctl plugin install` (or `claude plugin marketplace add
deathemperor/infinitus` then `claude plugin install infinitus@infinitus`).
Set `INFINITUS_CTL` when `infinitusctl` is neither on PATH nor in
`/Applications/Infinitus.app`.
