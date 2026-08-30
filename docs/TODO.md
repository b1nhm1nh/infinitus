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
  advisory; regression tests.
- ~~All-limited looks broken~~ → engine emits `nextRecovery {number, at}`
  when no candidate is viable (last maxed window resetting soonest);
  the app's shared NextMarker renders it as a hollow gray triangle with
  a "recovers first (date)" tooltip, distinct from the green candidate.
- ~~Sync export/import~~ → SyncPane "File" section: Export…/Import… of
  the same SyncSnapshot the iCloud file carries (never credentials or
  push secrets); import marks the current remote as seen so the next
  tick pushes the import instead of pulling the old remote back.
- ~~Popup footer~~ → one row of Label buttons (Rotate/Refresh/Settings/
  Pin/Compact/layout/pop-out, then chips + engine badge + Quit trailing);
  "Test notification" retired (the Push pane keeps its own test);
  "Settings…" → "Settings".
- Onboarding (user, 2026-08-30): first-run experience — when someone
  installs Limitless.app without cswap, offer to install the engine
  (uv tool install / pipx / brew detection), walk through adding the
  first account, granting notifications. Today the app just shows an
  empty popup + engine errors.
- GitHub releases (user, 2026-08-30): "make it so" — publish
  Limitless.app releases on GitHub for non-developer users; app
  auto-update checks the releases feed (Sparkle or hand-rolled:
  check latest tag, download zip, replace bundle, relaunch). Build
  from source stays the developer path. Needs: repo push (explicit
  user approval exists for release flow), Developer ID signing or
  at least consistent ad-hoc + quarantine notes.
- Promotional content (user, 2026-08-30) — after the improvement wave
  settles:
  1. Repo README with the features list (menu bar usage, auto-switch,
     themes/gamification, glass popup, pace bars, multi-engine slots,
     iCloud sync, push notifications, sessions/status chips).
  2. Update the GitHub profile (deathemperor) to feature Limitless.
  3. Update huuloc.com (pensivie repo) with a Limitless section.
  4. Short feature walkthrough video — script + screen recording
     (popup tour, themes flip, switch celebration, settings, engines).
- Duplicate icon uses within a theme (user screenshot, 2026-08-30):
  movie uses 🎬 as BOTH the slot prefix and the session gauge label, so
  a row reads clapperboard-number … clapperboard-gauge; the dead marker
  📼/🔚 vs re-release icons overlap similarly. Audit every builtin so
  each icon appears in exactly ONE role (slot, session, weekly, scoped,
  credit, cash, ahead, dead, revive, next) and adjust vocabularies;
  also consider dropping the slot prefix when the row is dead (the
  dead marker already leads).
- ~~Tooltip z-index across rows~~ → InstantTip publishes through
  ActiveTipKey (anchor preference); MenuContent renders the one active
  chip in a root overlay canvas above every row. Verified live.
- ~~Dead-transition animation~~ → deathTicks diff in refreshSnapshot
  (alive->dead, nothing on first load), DeathFlash red-hit/flicker/
  slump; wide Grid via DeadRowBounds band, stacked cards wrap content
  (full saturation drain). Debug-pane button added. NOT yet seen live
  — fire 'Play the death beat' in the Animations pane to verify.
- ~~Duplicate icon roles~~ → movie session 🎬→🎥 + ahead popcorn→
  speedometer; hades next 🔥→🕯; swe ahead coffee→flame. Slot prefix
  KEPT on dead rows (mixed prefixes misalign the slot column).
- Settings sidebar detail appeared to lag one selection behind under
  SYNTHETIC clicks (2026-08-30 automation session; app not active/key).
  Check once with real clicks — if it reproduces, the wrapped
  NSHostingView in showSettingsWindow is the suspect.
- Visual verification pending: glass look, whole-row themed sweep,
  About icon, new themes, unified footer, sync export/import, hollow
  recovery triangle (needs an all-limited fleet to show).
- ~~Ahead-of-pace icon tooltips~~ → InstantTip on both sites, edge
  .above (the cell's own summary tip owns .below); alignment ghosts
  stop answering hover.
- ~~Menu bar remaining vs used~~ → "Menu bar counts remaining, not
  used" toggle; TitlePrefs.titleRemaining flips 5h/7d/scoped at
  display time. Popup gauges stay HP-style (already remaining).
- Dead-transition animation (user, 2026-08-30): when an account flips
  alive -> dead in a snapshot, play a death animation on its row (the
  themed dead marker landing — a drop/flicker/desaturate beat), the
  mirror of the refill celebration. Belongs in the Animations pane
  examples too.
- ~~Hide control center, keep chips~~ → "Hide popup actions (status
  chips stay)" Display toggle; wide footer, stacked rail, and compact
  strip all hide their buttons, chips + restart-to-update stay.
- ~~Right-click status-item menu~~ → just-in-time NSMenu (sendAction
  on .rightMouseUp; performClick with item.menu set, then detached so
  left-click keeps toggling): Theme submenu with checkmark, Rotate/
  Refresh, Pin (stateful), Pop out/in, Settings, Restart, Quit.
