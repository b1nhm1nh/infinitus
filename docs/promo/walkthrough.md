# Infinitus — feature walkthrough (script)

Target: ~90 seconds, no narration track needed (captions in the edit).
Recorded on the demo fleet (`cswap-shim`: alpha…echo, fabricated
usage) — never the real engine, so no account emails appear.

| # | Shot | On screen | Caption |
|---|---|---|---|
| 1 | Menu bar | The ∞ glyph with `alpha 37%·22%` beside it | "Every Claude account in one menu bar" |
| 2 | Click the glyph | The glass popup: five rows, HP/MP gauges, gold column, pace markers | "Live 5-hour / weekly / per-model headroom for the whole fleet" |
| 3 | Hover a gauge | Tooltip with reset countdown + pace | "Pace markers when a window burns faster than time passes" |
| 4 | Row 3 (charlie) | Dead row: 💀, "HP down", respawn countdown | "Dead rows say why — and when they're back" |
| 5 | Rotate button | Switch to the next candidate; the celebration sweep runs over the new active row | "One-click rotate, auto-switch aware" |
| 6 | Right-click the glyph → Theme | Flip RPG → Metal Gear → Cosmos → Off | "Themes reskin every label, marker and countdown" |
| 7 | Pop out | The pinned window, compact toggle | "Pop-out window, compact mode, remembers its spot" |
| 8 | Settings → Display / Themes / Engines | Toggles, the theme card grid, the resume-nudge switches | "Auto-order, glass dial, resume nudges into cmux/tmux/herdr" |
| 9 | Settings → Push | Slack/Discord/Telegram/webhook rows (masked) | "Switch and limit events pushed where you are" |
| 10 | Close | Back to the bar glyph | "brew install --cask deathemperor/tap/infinitus" |

Recording: `screencapture -v -V <seconds> -R x,y,w,h out.mov` per shot on
the shim fleet (`INFINITUS_CSWAP=$S/cswap-shim ./run-unbundled.sh`),
then `ffmpeg -f concat` the segments; keep the mp4 out of git.
