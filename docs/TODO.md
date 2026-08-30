# Open items (carried over from the claude-swap session, 2026-08-29)

## Done 2026-08-30
- ~~Caffeine integration~~ → built as a native power assertion instead
  (KeepAwake.swift, Display pane toggle); Caffeine.app path dropped —
  it required writing another app's prefs.
- ~~Session counter breakdown~~ → engine emits idle/waiting/shell/unknown
  (additive in `liveSessions`); shown in the brain chip's tooltip
  (user picked tooltip over chip).
- ~~Dev loop~~ → `UNBUNDLED=1 ./dev.sh` relaunches through
  run-unbundled.sh; relaunches debounced to one per 10s.

- ~~Switch celebration "looks broken"~~ → two causes, both fixed:
  Grid layout attached the sweep to the number cell only (now an
  anchor-preference overlay sweeping the whole row), and the sweep
  gradient carried the theme color at opacity 0 (pure white band for
  every theme) — shoulders now tinted + a themed wash glow.
- ~~Glass chrome~~ → NSVisualEffectView `.menu` material, behind-window,
  on the popover content and the (now non-opaque) pop-out window; on
  macOS 26 a Liquid Glass layer (`glassEffect(.regular, in: .rect)`)
  rides on the blur (glassChrome()). Drop one layer if it looks doubled.
- ~~iCloud sync setting home~~ → own "Sync" pane (SyncPane.swift).
- ~~Theme requests~~ → builtins `agent` ("AI Agentic — tokens & context")
  and `swe` ("Classic SWE — hand-written, no AI").
- ~~About pane icon~~ → real app icon when bundled; unbundled draws the
  menu bar glyph on the gradient card (the retired ∞ is gone).

- ~~Bundle id~~ → `com.huuloc.limitless`, done 2026-08-30 as the one
  intentional step: prefs copy-migrate from the g2 domain on first
  launch, themes.json copy-migrates from `CswapBar/`; re-grant
  notifications + login item once under the new id.

## Deferred by design
- Community theme gallery URLs point at `deathemperor/limitless` — 404s
  until the repo is pushed.
- Codex backend support: landscape researched (codex-rotate, codex-switcher,
  opencode plugin, openai/codex#9648); feasible as a second engine backend
  behind the same isolation boundary. Not requested.
- Router ecosystem (9router / n9router / ai-9router, 2026-08-30): local
  proxies that rotate provider accounts per-request via ANTHROPIC_BASE_URL.
  Opposite layer to cswap's credential swap — running both fights. If ever
  requested: detect ANTHROPIC_BASE_URL and show "routed via …" first;
  a router backend would be a second engine behind the same boundary.
- Real Notification Center delivery needs a Developer ID signature or one
  Xcode automatic-signing run (provisioning profile).

- ~~AppIcon ∞~~ → make-icon.swift now scales the MenuBarGlyph path
  (identity source of truth) onto the gradient squircle; icns rebuilt.
- ~~Sync "pushed" under an off toggle~~ → disable-mid-tick race; tick()
  re-checks `enabled` after its await before any write.

## Open
- Next-candidate indicator "seems missing" (user, 2026-08-30) — diagnosed
  NOT broken: every non-active account is at 100% on some limit (1 spend,
  2 weekly, 3 five-hour, 4 scoped), so the engine's advisory
  `_next_switch_candidate` honestly returns none and the triangle hides.
  UX flaw: "no viable candidate" is indistinguishable from broken.
  Candidate fix: engine falls back to "recovers soonest" among the
  exhausted (soonest reset), app renders that state distinctly (e.g.
  hollow/gray triangle + tooltip "all accounts limited; N recovers first").
- Sync settings: export and import config (user, 2026-08-30) — SyncPane
  gains Export…/Import… of the app's settings (the synced key set) as a
  JSON file; import applies via the existing merge path.
- Visual verification of the 2026-08-30 batch pending: glass look,
  whole-row themed sweep, About icon, new themes.
