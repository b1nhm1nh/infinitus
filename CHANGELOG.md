# Changelog

Composed release notes — what changed and why it matters, not a list of
commit links. The release workflow publishes the matching section as the
GitHub release body.

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
