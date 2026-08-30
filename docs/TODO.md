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
- ~~Onboarding~~ → engineMissing welcome card in the popup: what the
  engine is, Install button (uv tool install claude-swap via Process,
  then relaunch re-runs the locator), manual commands shown. Intro
  modifiers no longer hold content hidden when no data will ever come;
  LIMITLESS_CSWAP env override ('' = no engine) makes it testable.
  Notifications/add-account walkthrough still open for later.
- ~~Settings window absent from Cmd+Tab~~ (user, 2026-08-30) → the
  app flips to .regular activation policy while Settings is open
  (Dock + Cmd+Tab entry) and back to .accessory on willClose.
  Verified live both directions.
- GitHub releases (user, 2026-08-30): "make it so" — publish
  Limitless.app releases on GitHub for non-developer users; app
  auto-update checks the releases feed (Sparkle or hand-rolled:
  check latest tag, download zip, replace bundle, relaunch). Build
  from source stays the developer path. Needs: repo push (explicit
  user approval exists for release flow), Developer ID signing or
  at least consistent ad-hoc + quarantine notes.
- Promotional content (user, 2026-08-30) — after the improvement wave
  settles:
  1. ~~Repo README features list~~ → done 2026-08-30 (local commit).
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
  (full saturation drain). Debug-pane button added. Animation verified
  in an isolated probe 2026-08-30 (red hit + drain + settle, frames
  captured); in-app trigger still worth one human click of 'Play the
  death beat' (synthetic clicks can't actuate Form buttons).
- ~~Duplicate icon roles~~ → movie session 🎬→🎥 + ahead popcorn→
  speedometer; hades next 🔥→🕯; swe ahead coffee→flame. Slot prefix
  KEPT on dead rows (mixed prefixes misalign the slot column).
- ~~Settings sidebar detail lag~~ → root-caused to NavigationSplitView
  in the controller-owned window (detail froze entirely under synthetic
  clicks); SettingsRoot is now a hand-rolled sidebar of plain Buttons
  and the detail follows selection. Residual: FORM buttons in the
  detail panes still refuse synthetic clicks (sidebar + popup buttons
  actuate with a focus-first click); real clicks unaffected.
- Pop-out in COMPACT mode: the header strip overlaps the first row
  (seen 2026-08-30 restoring a compact pop-out at launch, window 158pt
  vs ~166 ideal). Check whether a manually opened compact pop-out does
  the same — suspect the measured fixedSize vs the ignored top safe
  area, not the new restore path.
- Visual verification pending: About icon, sync export/import, hollow
  recovery triangle (needs an all-limited fleet to show). Glass,
  themed sweep, footer, new themes: verified 2026-08-30.
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

## Shipped 2026-08-30 (evening wave — 15 numbered asks + follow-ups)
- ~~Theme preview ': :' rows~~ → macOS 26 VStack ideal-height bug;
  per-row fixedSize; preview bars animated:false. Verified in probe.
- ~~Custom theme reconcile~~ → templateJSON, themes/README table, and
  the synthwave sample now carry every RowTheme field.
- ~~Plain-theme skull~~ → Off theme's dead marker is ✕.
- ~~New themes~~ → Sci-Fi, Wild West, Cyberpunk, Gothic builtins
  (one role per icon each); ThemeColor learned brown. Verified live.
- ~~Theme selection revamp~~ → Themes settings pane: builtin/custom
  card grids + community gallery moved out of Display. Verified live.
- ~~Settings reorder~~ + ~~search box top space~~ → hand-rolled
  SettingsRoot, most-used panes first. Verified live.
- ~~Visual layout/size pickers~~ → PickTile art tiles. Verified live.
- ~~Icon-only menu bar~~ → titleIconOnly override toggle (synced).
- ~~Engine updates into engine pane~~ → Engines → cswap hosts
  auto-update + check/upgrade; About keeps app releases. Verified.
- ~~Resume nudges into cswap pane~~ → status-first rows (check /
  warning + one-click fix, n/2-ready pill). Verified live.
- ~~Rows slide-in intro~~ → introStyle "rows", per-row stagger from
  the right (Group-in-GridRow distribution). Verified live at launch.
- ~~Compact rail responsive~~ → measured rows-column height vs counted
  rail items; five accounts + hidden actions = one column. Verified.
- ~~Pop-out persistence~~ → popout_shown/x/y; restored at launch
  without stealing focus (position verified to the point); Cmd+W
  clears. ~~Off-screen overflow~~ → clampOnScreen on every re-fit +
  anchored bottom clamp.
- ~~Switch push lists the fleet~~ → ENGINE side (claude-swap commit
  572e073): switch_text(fleet=…) + switcher.fleet_status_rows —
  '→ 2 bravo: 5h 45% · 7d 12%' lines under the head. Tests green
  (pre-existing env-dependent failures in move/swap/store-guard
  suites are unrelated).

