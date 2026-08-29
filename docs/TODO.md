# Open items (carried over from the claude-swap session, 2026-08-29)

## Asked for, not built yet
- **Caffeine integration** — keep the machine awake via the installed
  Caffeine.app (net.domzilla.caffeine 1.6.4). No URL scheme / AppleScript /
  notifications in the binary; only prefs (`CAActivateAtLaunch`,
  `CADefaultDuration`). Only viable path: set `CAActivateAtLaunch` in its
  domain and launch/quit Caffeine when sessions are busy. Needs the user's
  OK on writing another app's prefs (alternative: built-in `caffeinate`).
- **Session counter breakdown** — chip shows only `status == "busy"`
  sessions from `~/.claude/sessions/*.json`; idle / unknown (sdk-cli) /
  shell aren't counted. Proposed: engine emits idle/unknown counts,
  chip or tooltip shows `N working · M idle · K ?`. User to pick chip vs
  tooltip.
- Dev loop: point `dev.sh` at `run-unbundled.sh` while the session is
  wedged, and add a debounce (rapid relaunch churn is what wedged it).

## Deferred by design
- Bundle id → something like `com.huuloc.limitless` as ONE intentional
  step (re-grant notifications + login item afterwards).
- Community theme gallery URLs point at `deathemperor/limitless` — 404s
  until the repo is pushed.
- Codex backend support: landscape researched (codex-rotate, codex-switcher,
  opencode plugin, openai/codex#9648); feasible as a second engine backend
  behind the same isolation boundary. Not requested.
- Real Notification Center delivery needs a Developer ID signature or one
  Xcode automatic-signing run (provisioning profile).
