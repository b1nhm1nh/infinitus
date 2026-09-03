# Changelog

Composed release notes — what changed and why it matters, not a list of
commit links. The release workflow publishes the matching section as the
GitHub release body.

## 0.4.1 (unreleased)

### Menu bar
- **The reset time, in the bar.** The title now ends with when the
  active account's fuller window resets — `loc · 75·40% · ↺2h14m` — the
  one number a one- or two-account user actually waits on. Settings →
  Display → *Reset time in title*: countdown (default), clock time, or
  off. The Linux tray title carries the same countdown.
- **Stars you can see.** The pick-first star shows in every account
  list (popup grid, cards, the phone), and starring an account that
  isn't active switches to it at once; the star itself flips
  immediately and settles when the engine confirms.
- **Install engine bootstraps `uv`** instead of dead-ending on
  "uv not found" (Homebrew if present, else Astral's installer) —
  thanks @sonyy172 (#20).

### One account
- **The solo card.** With a single account the popup drops the fleet
  grid for one card: name and plan up top, every window on its own
  line with a gauge three times the grid's and the full reset text
  beside it — the reset is the whole story when there is nothing to
  rotate to. Under it, one line on why a second account is worth
  having, with "Add account…" opening the sign-in right there. Two
  accounts keep the grid; the menu bar countdown above serves both.

### Docs
- `docs/guides/agent-setup.md`: a from-scratch setup recipe for a
  coding agent — install, engine, accounts, auto-switch knobs, menu
  bar, verification.

### 9Router engine
- **A third engine.** [9Router](https://github.com/decolua/9router)
  joins cswap and CLIProxyAPI: its Claude connections show up as a
  fleet with 5h / 7d / per-model gauges, switch (priority), hold and
  remove, all through its dashboard API on loopback with the dashboard
  password kept in the keychain. Rotation stays 9Router's own; Infinitus
  only sets its knobs. Settings → 9Router to turn it on;
  `infinitusctl engine 9router on` and `9router-password` from a script.
- **Every 9Router provider, not just Claude.** One fleet per provider
  the app knows (Claude first, then Kiro / Codex / Gemini by name).
  Kiro's monthly credit pool rides the row's credit gauge in credits —
  used / total, reset date — with "KIRO POWER" in the subscription tip;
  spent credit counts as dead for a credit-only row. Switching between
  Kiro connections goes through 9Router's priority like Claude's, though
  9Router routes Kiro traffic itself — the row is there for the stats.

### Bundle id
- **`com.huuloc.infinitus`.** The macOS bundle id now matches the app
  (it was `com.huuloc.limitless` since the rename). Settings carry over
  on first launch; macOS asks again for Notification Center and the
  Login Item under the new id, and each keychain item (proxy key,
  9Router password, tunnel, APNs) prompts once.

### AWS sign-in from the phone
- **Sessions that need `aws login` get one.** When a session's newest
  tool result carries the expired-session signature ("Please
  reauthenticate using 'aws login'", the cred broker's "Fix: aws login
  --profile …"), the popup shows "🔐 <session> needs AWS login
  (<profile>)" and the phone gets the same item. Start it from the
  phone: Infinitus runs `aws login` on the Mac with the phone as the
  browser — the phone's web view intercepts the CLI's localhost
  callback and hands it back, so there is no code to read or type
  (SSO profiles take the device-code flow; `aws login --remote` with a
  pasted code stays as a fallback). Once the CLI reports success the
  session gets "AWS login for profile … completed, retry and continue"
  over the same channel the phone's replies use. Any failing aws
  command is the trigger; sessions need not call `aws login` at all.
  "Log in here" on the Mac runs the normal browser flow instead. The
  code goes straight into the CLI's stdin — never logged or stored;
  Infinitus never reads the AWS credential caches. `infinitusctl
  aws-logins` / `aws-login <profile> [--local]` / `aws-login-code`.
- **Detection tuned on the first real run.** The scan covers every
  listed session, not just busy ones — a session that hit the expiry
  has stopped on it and is idle by the time the scan runs — and its
  window counts message entries, so the hook/attachment lines a turn
  appends can't push the failure out of view. The signature has to
  open an output line: the same words quoted from a source file, a
  grep hit or a Read no longer flag the session reading them. Two more
  CLI messages count ("pending authorization … has expired", "security
  token … is expired"). When the CLI asks whether to rebind the profile
  to the account the browser signed into, the runner answers no and
  reports which account you landed in — a silent rebind is how a
  profile ends up on the wrong account.
- **The whole flow is in the e2e gate.** `tools/e2e.sh` plants a
  fake Claude session whose transcript died on the expired sign-in,
  runs the code flow against a stub `aws` CLI (`INFINITUS_AWS_CLI`),
  and checks the need surfaces, the flag-less poll (`aws-login
  --status`) starts nothing, the session gets its continue nudge over
  its own inbox socket, the need clears, and a rebind is refused.
  Writing it found two holes: the Mac's own "Needs AWS login" line
  only followed the transcripts while the phone's LAN mirror was on,
  and a mock-mode instance never read transcripts at all.

### Prediction model
- **"At this pace" line in the popup.** Below the account rows: when
  each window of the active account hits its limit at the measured burn
  (MP / HP / per-model, named by the row theme) and when the whole
  fleet's weekly headroom would be gone — clock times, no ticking
  countdown. 5h pace from the last hour, weekly pace from the last 24h;
  the tooltip carries the paces. Same numbers as the battle plan's
  bind, so the two lines never disagree. `infinitusctl forecast` and
  the mirror snapshot's `forecast`/`plan` fields carry it to the phone.
- **The pace is on the line.** "At this pace (MP 39%/h · HP 4%/h ·
  Fable 4.7%/h): MP out ~4:12 PM · …" — the measured rates ride inline,
  the tooltip says where they come from in plain words.
- **Detail dashboard.** Utilization opens with the full forecast: every
  account at its own pace — each window's used %, rate, when it runs
  out, when it resets, which limit binds first — the fleet's all-out
  time with the drain order it assumes, the live battle plan steps, and
  the run rate with the live tokens/minute. `infinitusctl forecast` and
  the snapshot carry every account's line.
- **Run rate in Utilization.** Tokens, API-equivalent dollars and turns
  per minute / hour / day / week, read off Claude Code's own transcripts
  (a turn counted once, priced from the static table; unknown models
  named). Incremental: only bytes appended since the last scan are
  parsed, so after the first pass a refresh is instant. Plus a
  Projection section with the same forecast built from the history.
- **Plan line in plain words.** "Plan: when main hits its MP limit
  ~4:00 PM switch to loc → loc's MP resets 6:50 PM" instead of a bare
  "switch to loc 4:00 PM → loc resets 2:50 PM" — and a candidate whose
  window resets before the switch no longer gets a reset step dated
  before it.

### Battle plan (#7)
- **Ignite from any engine that can.** Starting a spare account's 5h
  clock is now an engine capability: cswap does it with `cswap run`; the
  CLIProxyAPI fleet has no per-credential request verb yet, so its plan
  line shows without the button. `infinitusctl ignite <fleet> <n>` does
  the same from a script.
- **No landing on a nearly spent window.** The planner only switches
  onto a window with at least 90 minutes left at the projected bind,
  ignited or already ticking — an ignited window that aged past that
  because the bind came late would give minutes and then a stall.

## 0.4.0

The phone release: your fleet and every Claude Code session reachable
from anywhere, a second engine, and the app learns to plan its 5-hour
windows.

### Remote access (#9)
- **Four ways in, one QR.** The iPhone app reaches your Mac over Wi-Fi
  (Bonjour), Tailscale, your own Cloudflare tunnel hostname (dashboard
  token or a local `~/.cloudflared/config.yml`), or a free quick
  tunnel. One pairing QR carries every route and the token; the phone
  keeps the list and falls through to whichever answers, and names the
  route that failed instead of saying "offline".
- **Rendezvous on infinitus.run.** A quick tunnel's throwaway URL is
  published under a hash of the pairing token, so a phone whose saved
  tunnel died fetches the new address instead of rescanning after every
  restart. Nothing else ever leaves your Mac.
- **Connected devices.** The Sync pane lists each phone with its route
  and last-seen time; a "Set up your phone" walkthrough with live checks
  and a "Copy for an AI agent" brief cover the setup.

### Session chat (#17)
- **Every session as a chat on the phone.** Recent transcript as bubbles:
  markdown replies, consecutive tool calls collapsed into one chip,
  sub-agent cards (type, description, tool count, running/done),
  prompts typed mid-turn, cross-session messages as "sender: body".
  Long-polled, so replies stream in as they're written.
- **Reply from the phone.** Answer questions and permission prompts by
  number, type a message, attach photos (library or camera, downscaled)
  and PDF/text files — delivered over Claude Code's peer socket, or typed
  into the terminal (cmux, tmux, herdr) when there is none. Tap the
  header for the account serving the session and its limits.
- **Sessions by name.** Rows use the session's own name (`/rename`) with
  branch, model, kind and output size; a "waiting on you" push fires once
  per session that stops for an answer.

### Engines and accounts
- **CLIProxyAPI backend (#8).** Fleets already running behind the proxy
  plug in through its Management API as a second engine: OAuth add,
  hold/remove, routing-strategy picker, keychain-held key. The app is a
  facade over any number of engine fleets; UI gates on capabilities.
- **Pick-first stars (#15).** Star an account and the engine lands on it
  first when it switches — cswap `autoswitch.preferred`, the proxy's
  priority tier. Policy stays in the engines; the app only sets knobs.
- **5-hour window telemetry (#7).** Windows reconstructed from usage
  history with rhythm and burn rate; a Utilization pane with a
  "Battle plan — dry run" that replays what deliberate ignite / switch /
  hold / reset would have done. Samples now record the active account.
- **Battle plan (manual).** Infinitus projects when the active account's
  5h window binds and offers to start a spare account's clock early so
  its reset lands mid-sprint — a live line in the popup with a two-tap,
  confirm-gated Ignite (`cswap run <n> -- -p . --max-turns 1`), and
  `infinitusctl plan`.
- **Weekly reset on full-HP rows (#16)**, 5h-dead rows keep their 7d
  reset, remembered resets say "last seen".

### Agents and tooling
- **`infinitusctl`.** A same-user control socket in the app and a
  manifest-driven CLI: status, fleets, switch / rotate / hold / rename /
  prefer / reorder / remove, add + wait-add, proxy settings, windows and
  perf probes. `tools/e2e.sh` round-trips every verb in CI with a perf
  gate. The socket re-binds itself if something clobbers its path.
- **Onboarding brief.** First-run card offers a pasteable recipe with
  this Mac's state ticked off, for a coding agent to finish the setup.
- **Resume nudges** go over the peer socket first (terminal typing only
  without one); a usage poll up to 60 s before a limit stop counts as a
  fresh verdict, so the session stopped by the switch itself is nudged.

### Performance (#18)
- Pop-out idle CPU 43% → 0.4%: every RPG effect and burn overlay runs as
  Core Animation on a layer host; the countdown no longer grows the
  glyph cache; the closed wall stops ticking. CI gates idle CPU and heap
  growth.

### Omarchy / Linux
- `infinitus-tray serve/pair`: the phone companion over a POSIX
  listener with the same routes, session tail/input, push triggers, and
  head-first rejection of unpaired callers. Panel shows each session's
  phase and footer chips (service, sessions, engine).

### Site
- infinitus.run carries the popup in every theme, an SEO/agent pass
  (OG card, JSON-LD, FAQ, llms.txt) and the pairing rendezvous.

## 0.3.0

The Linux release: Omarchy gets the full popup, and the fleet learns to
tell you more when things are tight.

### Omarchy / Linux
- **The fleet panel.** Clicking the Infinitus bar widget (any button) now
  opens a native Quickshell panel — the macOS popup, ported: per-account
  rows with themed usage gauges, dead / sentinel / disabled states, click
  a row to switch, rotate + theme stepper in the footer, keyboard driving
  (`1`–`9`, `r`, `[`/`]`, Escape). Rows slide in on open; gauges and
  highlights animate.
- **Release artifacts.** Tags now ship `infinitus-tray-linux-x86_64` and
  `-aarch64` (self-contained, `-static-stdlib`) plus an
  `infinitus-omarchy.tar.gz` with the Quickshell plugin and Waybar
  config.

### Both platforms
- **All-limited state, made useful.** When every account is at a limit,
  the popup/panel names the first account to recover with a live
  one-second countdown, marks its row, and counts the limit-stopped
  Claude Code sessions waiting to be resumed.
- **Behind-pace effect.** Weekly/model bars running behind the clock's
  expectation breathe a slow mint halo — the calm counterpart of the
  ahead-of-pace burn.
- **Rotation holds.** Hold any account out of auto-rotation and return
  it: a pause/play button on each Accounts row (macOS), right-click a
  panel row (Omarchy), `infinitus-tray disable/enable <n>` (CLI).
- **Headroom display order.** Popup/panel rows sort most-headroom-first
  with the active account and the next candidate pinned on top —
  display-only, slot numbers never move. Toggle in Accounts (macOS) or
  the widget settings (Omarchy).

### macOS
- **Settings over white apps.** The Settings window's glass now lays an
  appearance-following wash under the content, so the sidebar stays
  readable over a white app behind it.
- The playground gained a demo video (`docs/playground-demo.mp4`) and a
  per-window ScreenCaptureKit recorder (`tools/wincap.swift`).
