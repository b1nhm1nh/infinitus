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
- ~~Next-candidate indicator "seems missing"~~ → real bug, engine-side:
  the advisory `_next_switch_candidate` counted the spend-cap pct in its
  >=100 "dead" rule, but spend is an estimate and the real ranking
  (oauth.account_headroom) never consults it — a rested account (5h 0%,
  7d 1%) went advisory-dead on spend 100%. Spend dropped from the
  advisory; regression tests. Still open as UX polish: when ALL windows
  are truly at-limit, "no candidate" is indistinguishable from broken
  (hollow/gray triangle + "recovers soonest" would fix).
- Sync settings: export and import config (user, 2026-08-30) — SyncPane
  gains Export…/Import… of the app's settings (the synced key set) as a
  JSON file; import applies via the existing merge path.
- Popup footer (user, 2026-08-30): unify the two button rows into one,
  remove the "Test notification" button, add the missing icons —
  row 1 (Rotate to next / Refresh / engine badge, LimitlessApp.swift
  ~:283) is icon-less text buttons; row 2 (Settings/Pin/Compact/…)
  already has Labels. Merge into one row of Label buttons.
- Drop the "…" from the "Settings…" button text (user, 2026-08-30).
- Visual verification of the 2026-08-30 batch pending: glass look,
  whole-row themed sweep, About icon, new themes.
