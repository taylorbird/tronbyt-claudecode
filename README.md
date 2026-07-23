# claude-usage — Tronbyt app

Shows your Claude subscription usage limits (the same numbers as Claude
Code's `/usage` command) as radial ring gauges on a 64×32
[Tronbyt](https://github.com/tronbyt)/Tidbyt display.

![two rings](docs/images/demo-two-ring.gif)
![three rings](docs/images/demo-three-ring.gif)

- One ring per limit: 5-hour session, weekly, and (if your plan reports one)
  a model-scoped weekly limit. Green < 50%, amber 50–79%, red ≥ 80%.
- Top row counts down to whichever limit is closest to its cap
  (toggleable in the app config).
- Amber pixel in the top-right corner = showing cached data because the
  last fetch failed.

## How it works

Anthropic's usage endpoint needs an OAuth token that only Claude Code
logins hold, and its standalone OAuth flow is unreliable (persistent
429s on token exchange). So a small **companion server** runs on a
machine where Claude Code is logged in, borrows Claude Code's own
(always-fresh) credentials, and republishes just the usage JSON on your
network. The Pixlet app fetches that URL — no secrets on the Tronbyt.

```
Claude Code keychain ──> scripts/serve_usage.py ──> http://mac:8377/usage.json ──> claude_usage.star
```

## Setup

1. **Run the companion** on the Mac where you use Claude Code:

   ```
   python3 scripts/serve_usage.py --bind 0.0.0.0 --port 8377
   ```

   Stdlib only, no dependencies. `--bind 0.0.0.0` lets a tronbyt-server on
   another box reach it; it serves only usage percentages, no secrets.
   To keep it running across reboots, wrap it in a launchd agent (or just
   leave it in a tmux pane).

2. **Install the app**: upload `claude_usage.star` as a custom app in the
   Tronbyt web UI.

3. **Configure**: set **Data URL** to `http://<your-mac>:8377/usage.json`.

The display shows `SET DATA URL` until step 3, `TOKEN EXPIRED`/`HTTP n`
frames if the companion can't reach Anthropic, and keeps rendering cached
numbers (with the amber stale pixel) through short outages.

## Development

```
pixlet render claude_usage.star dev_mock=happy -o /tmp/out.gif --magnify 8
```

`dev_mock` presets: `happy`, `high`, `zero`, `scoped` (three rings),
`expired`, `outage`. `self_test=1` runs built-in asserts. See
`docs/api-notes.md` for the verified usage-endpoint response shape and
`docs/plans/` for the design history.
