# Claude Usage Tronbyt App — Design

**Date:** 2026-07-21
**Status:** Approved

## Purpose

A Pixlet (Starlark) app for a Tronbyt-served Tidbyt display that shows the
user's Claude subscription usage limits — the same 5-hour session and weekly
utilization percentages surfaced by Claude Code's `/usage` command — as radial
ring gauges on the 64×32 matrix.

## Data source

`GET https://api.anthropic.com/api/oauth/usage`

Required headers:

| Header | Value | Note |
|---|---|---|
| `Authorization` | `Bearer <oauth token>` | |
| `anthropic-beta` | `oauth-2025-04-20` | |
| `User-Agent` | `claude-code/<version>` | Without it, requests hit an aggressively rate-limited bucket (persistent 429s) |

Response shape (from community documentation of this endpoint):

```json
{
  "five_hour": { "utilization": 62, "resets_at": "..." },
  "seven_day": { "utilization": 31, "resets_at": "..." }
}
```

A `seven_day_opus` (or similar) object may be present on Max plans; the app
adapts its layout dynamically if a third limit is reported.

## Auth

The app config takes a single OAuth token, pasted into the Tronbyt web UI.

- **Preferred path:** the long-lived token from `claude setup-token`
  (`sk-ant-oat01-…`). No refresh logic in the app.
  **Unverified:** whether the usage endpoint accepts this token type.
  Implementation step 1 is an empirical `curl` test.
- **Fallback:** `scripts/get_token.py`, a one-time helper that performs its own
  OAuth PKCE login, creating a separate grant with its own refresh-token chain.
  This matters because Anthropic rotates refresh tokens on every use — reusing
  Claude Code's refresh token would invalidate the user's Claude Code login.
  In this mode the app refreshes the access token in Starlark and persists the
  rotated tokens via `cache.star`.

## Rendering (64×32)

- Two ring gauges side by side, each 24 px diameter, one per 32 px-wide half:
  **5H** (session) and **WK** (weekly). If a third (Opus) limit is reported,
  switch to three 20 px rings labeled `5H / WK / OP`.
- No arc primitive in Pixlet: the app walks angle steps from 12 o'clock
  clockwise, maps each step to (x, y) via `math.sin`/`math.cos` at radius
  ~11 px, and stacks 1×1 `render.Box` pixels with `render.Padding` inside a
  `render.Stack` (~70 pixels per ring).
- Fill color by utilization: green < 50%, amber 50–80%, red > 80%. Unfilled
  remainder is a dim gray track. Center shows the percentage in `tom-thumb`,
  colored to match the arc. A 5 px label row sits under each ring.
- Top row (~6 px): reset countdown for whichever limit is closest to its cap,
  e.g. `WK resets 2h14m`, computed from `resets_at`. Toggleable.
- Static frame; no animation. Tronbyt's normal render cadence updates it.

## Config schema

1. `token` (string, required) — OAuth token.
2. `show_reset` (toggle, default on).
3. `dev_mock` (hidden/dev toggle) — feeds canned JSON for testing render states.

Colors, thresholds, layout: hardcoded (YAGNI).

## Caching & error handling

- Usage JSON cached ~2 minutes (`cache.star`) to avoid hammering the endpoint.
- A second long-TTL (~24 h) cache entry keeps the last good response.
- **No token** → "SETUP: paste token" frame.
- **401/403** → red "TOKEN EXPIRED" frame.
- **429 / network failure** → render from the long-TTL cache with a dim
  stale-data dot in a corner; error frame only if no cached copy exists.

## Repo structure

```
claude_usage.star       # the app
manifest.yaml           # Tidbyt/Tronbyt app manifest
scripts/get_token.py    # only if the setup-token path fails
docs/plans/             # design + implementation plans
README.md               # setup instructions
```

## Testing

- Step 1: verify the endpoint + token type empirically with `curl`.
- Build rendering against `dev_mock` canned responses covering: 0%, 62%, 95%,
  three-ring Opus variant, expired token, stale-data fallback.
- `pixlet render --gif` eyeball checks per state; final happy-path render
  against the live endpoint.
