# Design: native macOS menu bar app

Date: 2026-07-28
Status: approved, not yet implemented

Replaces the current three-process Mac setup and retires the Docker deployment.

## Why

The project spent a week trying to run the updater off the Mac (Docker on an
arm64 server). Every failure traced to one cause: off-Mac means nothing keeps the
Claude OAuth token fresh, so the updater has to refresh it itself, and the refresh
grant is the fragile part. See "Verified facts" below for the measurements.

On the Mac, that entire problem disappears — Claude Code keeps its own token
fresh and the app just reads it. The off-Mac requirement was the source of the
difficulty, and it bought nothing: the display is only needed while sitting at
the Mac.

## Goals

- One signed `.app` in `/Applications`, menu bar icon, no background agents.
- Reads the local Claude Code credential; no credential pasting, no refreshing.
- Configurable tronbyt details (URL, device id, API key) in a settings pane.
- Renders the 64x32 frame in-process and pushes it to the tronbyt-server.
- Keeps the animated reset row the current display has.
- Honest failure reporting: never show a stale number as if it were current.

## Non-goals

- Running off the Mac. Explicitly abandoned.
- Any HTTP server. Port 8377 goes away.
- Usage history or trends. Current state only.
- App Store distribution (so no App Sandbox; Developer ID signing only).

## Architecture

Single process, no IPC, no local network:

```
ClaudeUsage.app
  │
  ├─ CredentialReader   SecItemCopyMatching -> "Claude Code-credentials"
  │                     (Keychain item owned by Claude Code)
  │
  ├─ UsageClient        URLSession GET api.anthropic.com/api/oauth/usage
  │                     every 120s; keeps last good + fetchedAt + error
  │
  ├─ MenuBarView        MenuBarExtra: "5H 48%", amber >=50, red >=80
  │                     dropdown: three limits, resets, last-updated, errors
  │
  ├─ FrameRenderer      Core Graphics -> 2 frames of RGBA 64x32
  │                     -> WebPAnimEncoder -> animated WebP
  │
  └─ TronbytPusher      POST {installationID, image:<base64>} every 60s
                        to $TRONBYT_URL/v0/devices/$DEVICE_ID/push
```

`UsageClient` is the single source of truth; the menu bar and the renderer both
read its published state. One fetch feeds both, so the menu bar costs no extra
API calls.

## Data flow

1. Timer (120s) → `UsageClient.fetch()` → Keychain read → GET usage.
2. On 200: store body, `fetchedAt = now`, clear error. On failure: keep the last
   good body, record the error, leave `fetchedAt` alone.
3. Menu bar renders from that state on every change.
4. Timer (60s) → `FrameRenderer` draws from the same state → `TronbytPusher`.

Staleness is derived, never assumed: `age = now - fetchedAt`.

| Age | Frame |
|---|---|
| < 6 min | normal, full colour |
| 6-60 min | normal colours plus an amber border — something is failing, but recently |
| > 60 min | **everything grey**: rings and numbers in `#555`, no colour coding, reset row replaced with `AS OF 11:42` (local time of the last good fetch) |

Greying rather than replacing the numbers with an error screen is deliberate. The
rule to satisfy is "never present a stale number as if it were current", and grey
does that while keeping the information visible; a red error frame hides the data
and reads as an alarm about the wrong thing. `AS OF <time>` is more useful than an
age — it answers "how old" without arithmetic.

The one-hour threshold suits the real failure mode: the numbers move slowly enough
that a few minutes behind is unimportant, and anything over an hour means
something is genuinely wrong or the Mac was asleep.

### Sleep

Sleep breaks the derived-staleness model: if the Mac sleeps, nothing is running to
push, so the device holds the last full-colour frame indefinitely and cannot mark
itself stale. Handle it explicitly:

- On `NSWorkspace.willSleepNotification`: render and push the grey variant
  immediately, so the display marks itself not-live as it stops being live.
- On `NSWorkspace.didWakeNotification`: fetch and push fresh, out of band from the
  normal 60s timer, so it recovers immediately rather than up to a minute later.

This makes sleep visually indistinguishable from any other stale state, which is
correct — in both cases the numbers on screen are old and the reason does not
matter to a passing glance.

## Rendering

Port the ring math from `claude_usage.star` (`ring_pixels`, `pct_color`,
`countdown_text`) to Core Graphics. It is pixel arithmetic on a 64x32 grid, so it
translates directly; draw into a `CGContext` backed by an RGBA buffer rather than
compositing 1x1 boxes.

Two frames alternating the reset row (5H, then WK), 2500ms apart, matching today.

Encode with `WebPAnimEncoder` from libwebp:

- Dependency: `libwebp-Xcode` via SwiftPM.
- Verified 2026-07-28: `include/webp/` exposes `mux.h` and `mux_types.h`, and
  `sources: ["libwebp/src"]` is recursive, so `src/mux` is compiled. The anim
  encoder is reachable via C interop with no additional package.
- `Swift-WebP` is **not** needed: it wraps single-frame encoding only, and we
  only ever emit animated output.

## Configuration and secrets

| Value | Where | Why |
|---|---|---|
| tronbyt URL, device id, installation id | `UserDefaults` | Not secret |
| tronbyt API key | Keychain (our own item) | Currently sits in cleartext in a launchd plist |
| Claude credential | Keychain, owned by Claude Code — read only | Never copied or persisted by us |

Settings pane validates by doing one test push and reporting the HTTP status.

## Error handling

| Condition | Menu bar | Frame | Notes |
|---|---|---|---|
| Healthy | `5H 48%` | gauges | |
| Fetch failing, data < 60 min old | last value + warning tint | gauges + amber border | transient |
| Fetch failing, data > 60 min old | `5H --` | all grey + `AS OF <time>` | never show a frozen number as current |
| Mac asleep | n/a | all grey + `AS OF <time>`, pushed on the sleep notification | see Sleep above |
| Keychain read denied | `5H --` | error frame | prompt user to re-authorise |
| Not logged in to Claude Code | `5H --` | error frame | actionable message |
| Push failing | unaffected | n/a | menu bar shows last push status |

The Keychain item belongs to Claude Code, so the first read triggers a macOS
consent prompt ("Always Allow" clears it). It can re-prompt if our signing
identity changes. Fallback if that proves annoying: a settings field to paste a
credential.

## Testing

- Unit: ring geometry and colour thresholds against known percentages; countdown
  formatting; staleness tier boundaries (6 min / 60 min), including that the grey
  variant emits no colour-coded pixels at all.
- Golden-image: render a fixed payload, compare bytes to a committed reference
  frame — catches accidental visual regressions.
- Encoder: decode our own animated output, assert 2 frames and 2500ms timing.
- Integration: fake usage payloads (healthy / stale / error) through render and
  push against a local stub server.
- Manual: one real push per state, eyeballed on the device.

## Migration

1. Ship the app; verify it pushes correctly alongside nothing else running.
2. `launchctl unload` and delete both plists:
   `com.tbird.claude-usage-serve`, `com.tbird.claude-usage-push`.
3. Delete the dead `claude_usage` app registration in the tronbyt web UI (a
   leftover from the abandoned pull model; a persistent source of confusion).
4. Rotate the tronbyt API key — it has been in cleartext in a plist and was
   surfaced in a session transcript.
5. Retire `docker/` and `scripts/`. Keep `claude_usage.star` in the repo as the
   visual reference the Swift renderer is ported from, marked as no longer the
   live implementation.

Accepted trade-off: retiring the `.star` loses a portable artifact that could run
on any Tidbyt/tronbyt server. Acceptable given the Mac-only decision, but it is a
real loss and was decided deliberately.

## Verified facts (2026-07-28)

Measured, so nobody re-litigates them:

- **The usage endpoint requires the `user:profile` scope.** `/api/oauth/usage`
  returns `403 permission_error: OAuth token does not meet scope requirement
  user:profile` without it.
- **`claude setup-token` is a dead end for this project.** Its token
  authenticates but lacks `user:profile`, and the command exposes no scope flag.
- **The refresh grant returns 429 for this account's real credential**, observed
  repeatedly in container logs over ~a day. That is the load-bearing evidence.
  Also measured: a malformed body returns a clean `400`, `GET
  platform.claude.com/` returns `200`, and `console.anthropic.com` returns 429
  identically — so the host is reachable and processing requests, and the 429 is
  specific to the `refresh_token` grant.
  **Scope unknown.** A deliberately bogus refresh token also returns 429, but
  that does NOT show the limiter ignores the credential: rate-limiting invalid
  credential attempts is ordinary anti-brute-force behaviour, so the bogus-token
  result cannot distinguish an account/credential limit from an IP one. Testing
  from a different egress IP with a real credential would; nobody has.
- **macOS cannot encode WebP.** `CGImageDestinationCopyTypeIdentifiers()` on
  macOS 26.3.1 lists 22 types including `public.png` and `com.compuserve.gif`,
  but no WebP. Hence the libwebp dependency.
- **tronbyt documents WebP as the only push format.** Its `API.md` says nothing
  about validating or rejecting other formats, so GIF *might* work — untested,
  and moot now that we use libwebp.
- **Keychain mode needs no refreshing.** Reading Claude Code's credential and
  calling the usage endpoint works immediately and has no failure modes of its
  own, because Claude Code owns renewal.

## Open questions

- App icon and menu bar glyph: not chosen.
- Whether the settings pane should offer a "push now" button (probably yes, it
  makes validation obvious).
- Whether the grey variant should keep the rings at their last-known fill, or
  drop to empty rings. Keeping the fill preserves information; empty rings read
  more obviously as "no data". Decide by looking at both on the device.

Resolved 2026-07-28: sleep and long staleness both render as an all-grey frame
with `AS OF <time>`, pushed on the sleep notification (see Data flow → Sleep).
