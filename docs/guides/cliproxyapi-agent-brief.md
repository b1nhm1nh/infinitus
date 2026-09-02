# Agent brief: set up CLIProxyAPI for Infinitus

Paste everything below into a coding agent (Claude Code, Codex, …)
running on the machine where Infinitus lives. It does the parts that
are safe to automate and stops where a human must sign in or paste a
secret into the app.

---

You are setting up CLIProxyAPI (https://github.com/router-for-me/CLIProxyAPI)
as an account engine for Infinitus, a macOS menu-bar app that manages
several Claude accounts. Infinitus talks to the proxy only over its
Management API on `http://127.0.0.1:8317/v0/management`, authenticated
with the proxy's `remote-management.secret-key`. Do the following, in
order, verifying each step before the next. Never print, log, or commit
secrets; never edit files under `~/.cli-proxy-api/*.json`.

1. **Install and start.** macOS: `brew install cliproxyapi && brew services start cliproxyapi`.
   Linux: run the installer at
   `https://raw.githubusercontent.com/router-for-me/cliproxyapi-installer/refs/heads/master/cliproxyapi-installer`.
   Verify: `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8317/v0/management/auth-files`
   prints `404` (management API present but disabled) or `401`.

2. **Locate the config.** macOS Homebrew: `$(brew --prefix)/etc/cliproxyapi.conf`.
   Linux/Docker: `~/.cli-proxy-api/config.yaml`. Back it up next to
   itself as `<file>.bak-<date>` before editing.

3. **Generate two secrets** with `openssl rand -hex 24`: one management
   key, one API key. Write them to a mode-600 file the user chooses
   (suggest `~/.cli-proxy-api/infinitus-secrets`, one per line,
   labelled). Tell the user the file path; do not echo the values.

4. **Edit the config** (YAML, keep everything else intact):
   - `remote-management.allow-remote: false`
   - `remote-management.secret-key: "<management key>"` (plaintext —
     the proxy hashes it on start, which is why the copy in step 3 matters)
   - under `api-keys:` replace the placeholder entries with the API key
   - `routing.strategy: "fill-first"` (so Infinitus' Switch is real;
     the proxy default `round-robin` breaks Claude's prompt cache unless
     `routing.session-affinity: true`)

5. **Restart and verify.** `brew services restart cliproxyapi` (or the
   Linux service). Then
   `curl -s -H "Authorization: Bearer $(sed -n 1p <secrets file>)" http://127.0.0.1:8317/v0/management/auth-files`
   must return `{"files":[]}`, and
   `.../v0/management/routing/strategy` must return `{"strategy":"fill-first"}`.

6. **Point Claude Code at the proxy.** Merge into `~/.claude/settings.json`
   (create `env` if missing, keep other keys):
   ```json
   "env": {
     "ANTHROPIC_BASE_URL": "http://127.0.0.1:8317",
     "ANTHROPIC_AUTH_TOKEN": "<API key, not the management key>",
     "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1"
   }
   ```
   Do this only if the user confirms they want Claude Code routed
   through the proxy from now on; if cswap is their active engine, the
   two fight over the same accounts — ask first.

7. **Hand off to the human.** Print these instructions verbatim:
   - Infinitus → Settings → CLIProxyAPI: paste the management key from
     `<secrets file>`, Test connection ("reachable — 0 credential
     files, routing fill-first"), Save & restart, Engine on.
   - Infinitus → Settings → Accounts → "Claude — CLIProxyAPI" → Add
     account… → sign in per account (private in-app sheet or window;
     never the default browser).
   - Optional: Settings → CLIProxyAPI → Routing to change strategy.

8. **Final check** after the human adds an account:
   `.../v0/management/auth-files` lists it with `"status":"active"`,
   and a new `claude` session works. Stop there; do not touch the
   credential files, do not add accounts yourself (the OAuth flow needs
   the human's browser session).

Reference: `docs/guides/cliproxyapi-setup.md` in the Infinitus repo for
the human-facing walkthrough and the routing/caching notes.
