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
- ~~Community theme gallery URLs 404~~ → repo pushed 2026-08-30;
  index.json + synthwave fetch verified live (HTTP 200).
- Codex backend support: landscape researched (codex-rotate, codex-switcher,
  opencode plugin, openai/codex#9648); feasible as a second engine backend
  behind the same isolation boundary. Not requested.
- Router ecosystem (9router / n9router / ai-9router, 2026-08-30): local
  proxies that rotate provider accounts per-request via ANTHROPIC_BASE_URL.
  Opposite layer to cswap's credential swap — running both fights. If ever
  requested: detect ANTHROPIC_BASE_URL and show "routed via …" first;
  a router backend would be a second engine behind the same boundary.
- Developer ID signing: proven end-to-end 2026-09-01 under the company
  team (cert → notarytool Accepted → staple → spctl pass → 5 CI
  secrets), then UNSIGNED same day on user request ("I'll be providing
  a new account"): secrets deleted, identity removed from the keychain,
  CI back on the ad-hoc path. The runbook is exercised — redoing it
  with the new account is ~10 min (docs/RELEASING.md). Cert artifacts
  left on disk for the user to discard (~/Desktop/devid-csr,
  ~/Downloads/AuthKey_339Q7369BM.p8 — p12 unopenable, its password
  died with the secret).

- ~~AppIcon ∞~~ → make-icon.swift now scales the MenuBarGlyph path
  (identity source of truth) onto the gradient squircle; icns rebuilt.
- ~~Sync "pushed" under an off toggle~~ → disable-mid-tick race; tick()
  re-checks `enabled` after its await before any write.

## Open — tracked as GitHub issues since 2026-09-01

Open work lives at github.com/deathemperor/infinitus/issues (user
2026-09-01: "move todo items to use github issues tracking"); this
file keeps the shipped log and the deferred-by-design notes.

- #1 All-dead Live Activity (iOS + macOS equivalent)
- #2 Working-sessions Live Activity design
- #3 Slack push mirror to mobile
- #4 Capture quality (window captures + bright backgrounds)
- #5 Resume nudge typed but never submitted (Enter delivery)
- #6 Playground simulations (onboarding + auto-switch scenarios)
- #7 Infinitus smart engine — reset battle plans, window-start
      scheduling, capacity advice ("the big Infinitus"; plan last)
- ~~#8 CLIProxyAPI alternate backend~~ → shipped 2026-09-02 as the
  multi-engine seam: `AccountEngine` + `EngineFleet` + capabilities in
  InfinitusCore, `FleetState`/`EngineRegistry` in the app (AppModel stays a
  FleetModel facade over the primary Claude fleet), `FleetStack` popup
  sections, `CLIProxyEngine` over the Management API (keychain key,
  hold/switch-as-priority/rename/remove/OAuth add/usage ledger), Engines
  pane with both toggles + layer-fight warning; dev proxy installed via
  brew (docs/research/multi-engine.md §6/§9). Same day: module renamed
  InfinitusCore with per-engine dirs; proxy sign-in through the in-app
  chooser (`is_webui=true`, shared per-account cookie jar); Accounts tab
  lists every fleet with one row design; usage polled once per account
  (cache + per-email dedupe + `offerSharedUsage`). Verified live with two
  credentials. Follow-ups: routing-strategy picker (+ session-affinity
  note), switch/remove live round-trip on a throwaway credential,
  fixtures from redacted live captures, mirror carrying `[EngineFleet]`
  for the phone, Linux tray build check, upstream quota endpoint PR.
  Codex onto AccountEngine parked (user 2026-09-02: focus on Claude).
- #9 Mobile companion app (brainstorm done, user picks pending)
- #10 Human handoffs: AUR publish, Linux real-account cswap, signing
- ~~#11 Full-screen mode~~ → shipped 2026-09-01 (Display → Fleet wall,
      screen picker, scaled popup body, Esc leaves)
- ~~#12 Fleet wall layout~~ → shipped 2026-09-01 (mission-control
      hero/rail/bench; wall is a mode — popup/pop-out close)
- #13 Session progress tracking — watch agents, not accounts
      (zero-token transcript parsing + optional Claude narration;
      brainstorm in docs/research/session-progress.md)

## Shipped 2026-09-01/02 (session progress, site, mobile v0)
- ~~#13 Session progress (layers 0+1)~~ → SessionProgress transcript
  parser (todos, nowDoing, goal, retrying, quiet minutes), sessions
  popover rows, wall session board, Linux panel sessions section.
- ~~#14 Landing page~~ → infinitus.run (Cloudflare Workers assets):
  real captures, 1080p popup video, 15 full-popup theme images, brew
  cask, subtle Linux/Omarchy downloads, SEO/agent pass (JSON-LD, FAQ,
  OG card, llms.txt, sitemap).
- ~~"loc recovers in" wrong reviver~~ → RecoveryMath corrects the
  engine's next_recovery (which skips the active account), both OSes.
- ~~#7 layer 1~~ → WindowTelemetry (5h window reconstruction, daily
  rhythm) + Utilization "5h windows" section.
- ~~#9 mobile v0 + fidelity plumbing~~ → FleetMirror seam (mac +
  Linux tray exporters, FleetPrefs travel with the snapshot), iOS app
  scaffold (XcodeGen), InfinitusUI shared target: gauges, burn, theme
  colors, effects, rows/cards generic over FleetModel — pixel-verified
  unchanged on mac. Directive: pixel-perfect; portrait = stacked
  cards, landscape = wide list.
- ~~Popup Rotate/Refresh buttons~~ → retired (obsolete with
  auto-rotation); both stay in the status-item menu. Linux panel's
  footer Rotate button dropped too (`r` key still rotates).
- Omarchy aarch64 VM: built via chroot repairs; expect driver must
  answer busybox ash's ESC[6n cursor query or sends get eaten.

## Shipped 2026-09-01 (second wave — the remote-control batch)

- ~~Usage utilization history~~ → UsageHistory JSONL per machine
  (email-keyed, engine-poll stamped) + WasteMath weekly generations;
  recorders on BOTH OSes (AppModel actor / TrayHistory on the Waybar
  heartbeat, demo engines excluded); Utilization settings pane (range/
  window/account pickers, waste rows with observation-gap honesty);
  iCloud Drive mirror per machine when settings sync is on, merged at
  read. Verified live on the real fleet.
- ~~Onboarding~~ → ClaudeCLIDetect (~/.claude.json oauthAccount) +
  CLIProxyDetect (presence + credential-file count, contents never
  read; a real ~/.cli-proxy-api was found on this machine) + port
  probe; engine-missing card gains detection lines, empty-fleet gains
  FirstAccountCard with one-click `cswap add`; tray tooltip names the
  adoptable login. Empty-fleet was blank — IntroContentReveal held
  content for rows that never come; snapshotLoaded releases it.
  Simulated live: INFINITUS_CSWAP="" and DEMO_EMPTY=1.
- ~~Dying-account flash~~ → macOS CriticalPulse (red breath over rows
  whose binding window is ≥90%, riding the DeadRowBounds anchors);
  Omarchy panel pulses the urgent border (recovery holds steady, the
  pulse is the signal). Verified in the playground.
- ~~Dead-by-5h rows~~ → weekly/spend/per-model gauges stay visible
  with timers skipped; the 5h cause line keeps its own countdown
  (wide/compact/stacked + panel). Verified: killed alpha shows
  "MP down · 2h23m" + HP/$/Dragon gauges timer-less.
- ~~Auto-resume bugs (3 of 4)~~ → ResumeGate: nudges need evidence
  AFTER the stop (switch since first sighting, or usage poll newer
  than the stop) + 10-min per-session cooldown surviving burned
  stopUuids; /rc sweep skips busy sessions and withholds the
  confirm-Esc while "esc to interrupt" shows; sweep idleness measured
  against the stop instant (a 7d wait no longer reads as idle).
  Remaining Enter-delivery report → issue #5.
- ~~Move todos to GitHub issues~~ → issues #1–#10; this file is the
  pointer + history.
- Also: consume-first "why account 1?" answered (at-limit escape +
  self-correction; engine settings verified); CLIProxyAPI Management
  API mapped (docs/research/cliproxyapi-backend.md); mobile companion
  brainstormed (docs/research/mobile-companion.md — effects parity,
  remote control, Teams); Developer ID signing proven then unsigned on
  request; native aarch64 Omarchy VM build launched (ggalancs/
  omarchy-arm-utm, vetted, official sources).

## Shipped 2026-09-01 (the 0.3.0 wave — 8 todos, both OSes)
- ~~Omarchy right-click dead + anim/effects ask~~ → any-button click
  opens the panel (MouseArea acceptedButtons); rows intro, hover/active
  color motion, gauge fills already animated.
- ~~Glass over white apps~~ → GlassScrimView appearance-following wash,
  Settings window only (popup/pop-out keep the tuned dial); playground
  `settings` command via AppDelegate.shared.
- ~~All-dead: waiting sessions + first-reviver countdown~~ → banner with
  live 1s countdown (RecoveryCountdown, TimelineView / QML Timer),
  Transcript.findStopped count, orange marker + urgent border.
- ~~Behind-pace effects~~ → GaugeMath.chillDepth + breathing mint halo
  (macOS) / pulsing fill sheen (panel).
- ~~Disable accounts from rotation~~ → engine disable/enable surfaced:
  Accounts pause/play button, panel row right-click, tray verbs,
  demo-cswap verbs.
- ~~Sort by headroom, active + candidate pinned~~ → DisplayOrder.sort,
  display-only; Accounts toggle (synced sort_headroom) + panel
  sortByHeadroom setting (--engine-order opts out).
- ~~Composed changelogs~~ → CHANGELOG.md; release.yml publishes the
  version's section (--generate-notes only as fallback).
- ~~Release new version~~ → v0.3.0 tagged; first tag exercising
  linux-publish (Linux binaries + omarchy tarball on the release).

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


## Shipped 2026-08-30 (night wave — 6 asks + 3 mid-turn)
- ~~Theme preview "Fable"~~ → previews alias via theme.modelName.
- ~~Themed active-account icon~~ → RowTheme.activeIcon replaces the
  slot text (👑🌟🌿🐍🧠⌨️🧑‍🚀🏇⚡🕯); active outranks next.
- ~~Pop-out lost on restart~~ → quit's window teardown wiped
  popout_shown; AppDelegate.terminating guards pinnedClosed.
  Verified: seed → quit → flag survives → restore at position.
- ~~README à la CodexBar~~ → hero + badges + demo gif + Why/Install/
  Privacy/Credits (CodexBar credited as inspiration); MIT LICENSE.
- ~~Homebrew release~~ → repo public, v0.1.0 via release.yml
  (macos-26), rolling nightly prerelease, deathemperor/homebrew-tap
  with limitless + limitless@nightly casks; About updates via brew.
  E2E: brew install --cask deathemperor/tap/limitless → 0.1.0 in
  /Applications.
- ~~Animation GIF~~ → docs/demo.gif (launch intro + two rotate
  celebrations) recorded off a fabricated LIMITLESS_CSWAP shim
  fleet — no real account data in the published gif.
- ~~Linux/AUR ask~~ → app is AppKit (no Linux build); shipped the
  engine instead: claude-swap formula in the tap (Linux-capable,
  resources pinned, E2E-installed) + packaging/aur/PKGBUILD
  (publishing needs the user's AUR account).
- ~~Omarchy~~ → app not compatible (macOS-only) — README says so
  honestly; engine CLI on Arch/Omarchy highlighted instead.
- Open: Developer ID/notarization for quarantine-free installs;
  release workflow doesn't auto-bump the tap cask (manual sha step).
