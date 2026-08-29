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

## Deferred by design
- Bundle id → something like `com.huuloc.limitless` as ONE intentional
  step (re-grant notifications + login item afterwards). The App Support
  path `CswapBar/` moves in the same step.
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

## Open
- Switch celebration / data-change glow reported "looks broken" when
  test-fired (2026-08-30, debug Animations pane) — not reproducible
  headless; needs a description of which surface/layout and what it
  looks like before touching Animations.swift.
- Popup/pop-out chrome: adopt macOS glass (NSVisualEffectView /
  Liquid Glass material) for the popover and pinned window backgrounds
  (2026-08-30).
- "Sync settings via iCloud Drive" lives in the Display pane — wrong
  home; move to its own Sync/General settings pane (2026-08-30).
- Theme requests (2026-08-30): "AI agentic coding" and "classical
  software engineering (not using AI to code)" — new builtin RowThemes
  (labels for busy/dead/ready/credit etc. in each voice).
