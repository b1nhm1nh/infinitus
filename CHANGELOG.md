# Changelog

Product notes: concise, what you get and why it matters — no commit
links, no internals or workflow detail (user 2026-09-04). The release
workflow publishes the matching section as the GitHub release body.

## 0.4.2 (unreleased)

### All accounts limited
- **Floating revival countdown.** When every account is limited, a small
  always-on-top panel shows who recovers first, a live countdown and
  the sessions waiting to resume. Settings → Display to turn it off.

### Forecast
- "Binds at", "all accounts out" and the battle plan no longer drift
  later between polls.

### Phone
- **Continue a stopped session** from the phone — one button, whatever
  stopped it (a limit, a crash, a closed terminal).
- **Sessions is home.** The app opens on what's waiting for you, with a
  badge for how many; the Fleet tab opens with the active account, who's
  next and how many sessions are working.
- **Safer approvals.** A permission request is a card pinned above the
  composer with the full command; Allow asks once more, Deny is plain,
  and the phone taps back when it lands. Questions pick, then send.
- **Pairing starts on screen**: the empty Fleet tab scans the Mac's QR
  code, and says so when it's paired.
- Cleaner feed: tighter tool rows with errors in red, a loading and an
  empty state, "offline" up top where you can see it, and an ⓘ button
  to the session's details. Plain words for status; no process ids.
- Honors Reduce Motion; bigger tap targets and labels for VoiceOver.
- **Dictate a message.** A mic in the composer; on-device, no server.
- **Paste an image** from the clipboard, straight into the chat — the
  keyboard's "Paste from Screenshots" chip and the edit menu both work.
- **Notifications straight to the phone** (issue #3) — every alert the
  Mac posts, no Slack or Telegram in between. Ships once the phone
  build can register for them.
- Idle sessions show their names, not just the busy ones.
- **Pictures in the feed.** An image pasted in the terminal or sent
  from the phone shows as a thumbnail in the message; tap for full
  size. Images inside tool results stay text.
- Tool runs stay grouped through errors, with an error count on the chip.

### Agents
- `infinitusctl events` — the app's switch/death/revival log, so a
  "why did it switch?" question has a record to read.

### Linux tray
- Sessions that need an AWS login say so; the footer names the
  connected phone.

### Site
- infinitus.run reads well on phones: no sideways scroll, better
  contrast, feature cards grouped by what they do.

### Fixes
- A phone message no longer reads to the session like a note from
  another Claude session: it answers you in its own transcript instead
  of "replying" to a session named Infinitus.
- No more phantom permission cards: a tool running in a session that
  needs no approval was shown as "wants to run this" until the turn
  ended.
- Sessions moved into a git worktree show their feed again (the
  transcript stays under the repo's own folder).
- Keys and typed messages reach sessions inside cmux, where the
  terminal reports no process ids — matched by the session's name.
- The pop-out no longer freezes the app when it and its content
  disagree on size (a fractional height, a screen clamp, or content
  that measures differently in two window sizes kept the resize loop
  spinning on the main thread).
- Bright apps behind the popup, and window-only captures (CleanShot),
  no longer wash the glass out: it caps at a legible level at every
  transparency setting, and dark backdrops pass through untouched.
- The popup no longer burns CPU (and stops answering `infinitusctl`)
  while an account sits in the 90s.
- An engine that refuses to start no longer shows as a crash.

## 0.4.1

### Menu bar
- **Reset time in the bar.** The title ends with when the active
  account's fuller window resets — `loc · 75·40% · ↺2h14m`. Countdown,
  clock time or off, in Settings → Display. Linux tray too.
- **Stars you can see.** The pick-first star shows in every account
  list, and starring an account switches to it right away.
- **Install engine** sets up `uv` itself instead of stopping on "uv not
  found" — thanks @sonyy172 (#20).

### One account
- **The solo card.** One account gets one card: every window on its own
  line, big gauge, full reset time — and a one-line case for a second
  account with "Add account…" right there.

### Phone
- **AWS sign-in that survives a passkey.** Sign in from the phone: the
  AWS page opens in Safari, the code pastes in with one tap. The session
  that needs it is a sticky bar above its chat and at the top of the
  sessions list.
- The hide-keyboard button is gone — drag or tap to dismiss.

### AWS sign-in
- **Sessions that need `aws login` say so** — "🔐 <session> needs AWS
  login (<profile>)" in the popup and on the phone — and can be signed
  in from either. Once done, the session is told to retry and continue.
  The code never touches disk or logs.

### Forecast
- **"At this pace"** under the account rows: when each window of the
  active account runs out at the measured burn, and when the fleet's
  weekly headroom is gone — clock times, paces inline.
- **Detail dashboard** in Utilization: every account at its own pace,
  the fleet's all-out time, the battle plan steps, and the run rate in
  tokens, dollars and turns per minute / hour / day / week.
- The plan line reads as a sentence: "when main hits its MP limit
  ~4:00 PM switch to loc → loc's MP resets 6:50 PM".

### Battle plan
- **Ignite from any engine that can** (`infinitusctl ignite`), and the
  planner never lands on a window with under 90 minutes left.

### 9Router engine
- **A third engine.** [9Router](https://github.com/decolua/9router)
  connections show up as fleets — Claude, Kiro, Codex, Gemini — with
  their gauges, switch, hold and remove. Kiro's monthly credits ride the
  credit gauge. Settings → 9Router.

### Playground
- Every fleet scenario is a button: Normal / Empty / All dead / One
  account / Two accounts / No engine / Two engines.

### Docs
- `docs/guides/agent-setup.md`: set Infinitus up from scratch with a
  coding agent.

### Bundle id
- Now `com.huuloc.infinitus`. Settings carry over; macOS asks once more
  for notifications, the login item and each keychain item.

## 0.4.0

The phone release: your fleet and every Claude Code session reachable
from anywhere, a second engine, and the app learns to plan its 5-hour
windows.

### Remote access
- **Four ways in, one QR.** Wi-Fi, Tailscale, your own Cloudflare
  tunnel, or a free quick tunnel — one pairing QR carries every route,
  and the phone uses whichever answers. A quick tunnel's new address
  finds the phone by itself after a restart.
- **Connected devices** in Settings → Sync, with a "Set up your phone"
  walkthrough.

### Session chat
- **Every session as a chat on the phone.** Replies, tool calls
  collapsed into one chip, sub-agent cards — streamed as they're written.
- **Reply from the phone.** Answer questions and permission prompts, type
  a message, attach photos and files. Tap the header for the account
  serving the session.
- Sessions listed by name, with branch, model and output size; a
  "waiting on you" push when one stops for an answer.

### Engines and accounts
- **CLIProxyAPI** as a second engine: OAuth add, hold/remove, routing
  strategy, key in the keychain.
- **Pick-first stars.** Star an account and the engine lands on it
  first when it switches.
- **5-hour window telemetry** and a **battle plan**: Infinitus projects
  when the active account binds and offers to start a spare account's
  clock early so its reset lands mid-sprint — two taps, confirm-gated.
- Weekly reset shown on full rows; remembered resets say "last seen".

### Agents
- **`infinitusctl`**: status, fleets, switch / rotate / hold / rename /
  prefer / reorder / remove, add, proxy settings, perf. A first-run
  recipe a coding agent can finish for you.
- Resume nudges reach a session over its own socket first.

### Performance
- Pop-out idle CPU 43% → 0.4%; every effect runs on Core Animation.

### Linux
- `infinitus-tray serve/pair`: the phone companion on Linux, same
  routes, same chat.

### Site
- infinitus.run shows the popup in every theme.

## 0.3.0

The Linux release: Omarchy gets the full popup, and the fleet tells you
more when things are tight.

### Linux
- **The fleet panel.** Click the bar widget for the macOS popup, ported
  to Quickshell: themed gauges, dead/held states, click to switch,
  keyboard driving. Release artifacts for x86_64 and aarch64, plus an
  Omarchy bundle.

### Both platforms
- **All accounts limited, made useful.** The popup names the first
  account to recover with a live countdown, and counts the sessions
  waiting to resume.
- **Behind-pace glow** on bars running slower than the clock — the calm
  twin of the ahead-of-pace burn.
- **Rotation holds.** Keep any account out of auto-rotation and bring
  it back — a button on the row, or the CLI.
- **Most headroom first.** Rows sort by headroom with the active and
  next accounts on top; slot numbers never move.

### macOS
- Settings stay readable over a white app behind them.
- The playground has a demo video and a window recorder.
