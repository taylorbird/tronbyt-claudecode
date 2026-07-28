# Docker deployment (off-Mac, e.g. a Raspberry Pi or Docker server)

Runs the whole updater in **one container, one process**: it refreshes the
OAuth token, fetches your Claude usage, renders `claude_usage.star`, and pushes
the frame to the tronbyt-server — all in a single Python program on a timer.
Designed for a box on the same LAN as the tronbyt-server (the push model needs
only outbound connections; see the top-level README).

```
one container:
  loop: refresh token → fetch usage → serve on localhost → pixlet render → POST frame
                                                                              │
                                                        tronbyt-server ──> Tidbyt
```

(The process serves the usage JSON to itself on `127.0.0.1:8377` purely so
`pixlet` can fetch it the way the star app expects — it isn't exposed.)

> **New to Docker?** Follow [`INSTALL.md`](INSTALL.md) instead — it's a
> step-by-step walkthrough from installing Docker to a running container. This
> README is the shorter reference version.

## What you need first

- Docker + Docker Compose on the host (a 64-bit Raspberry Pi OS is `arm64`,
  which the image targets by default).
- Network reachability from the host to the tronbyt-server
  (`http://YOUR-TRONBYT-SERVER:8100`).
- A tronbyt device **API key** (tronbyt web UI → your device).
- Your Claude **credential value** — copied, not transferred as a file (below).

## The credential — passed in, not transferred

Off the Mac there is no Claude Code process keeping a token fresh, so the
process refreshes the OAuth token itself. It needs a starting credential that
contains a **refresh token**. You do **not** run any OAuth login flow yourself
(that PKCE token-exchange step is the one that rate-limits with `429`); you copy
the value a logged-in Claude Code already holds and paste it into `.env` as
`CLAUDE_CREDENTIALS_JSON`.

**From a Mac running Claude Code** — print the value and copy it:

```sh
security find-generic-password -s "Claude Code-credentials" -w
```

**From a Linux box running Claude Code** — it's the contents of
`~/.claude/.credentials.json`.

Either way the value looks like `{"claudeAiOauth":{"accessToken":"...",
"refreshToken":"...","expiresAt":<ms>, ...}}`. Paste that whole one-line blob
after `CLAUDE_CREDENTIALS_JSON=` in `.env`.

On first boot the process **seeds** `/config/credentials.json` (a Docker-managed
named volume, `claude-creds`) from that env value, then keeps the rotating token
in the volume across restarts. If the stored token ever dies, it falls back to
the `CLAUDE_CREDENTIALS_JSON` value again — so recovery is just pasting a fresh
value and re-running `up -d` (no volume surgery).

> **Important — don't share one refresh token between two active loggers.**
> Refresh tokens **rotate on every use**. If your Mac's Claude Code *and* this
> container both refresh the *same* token, they invalidate each other's copy and
> one of them gets logged out. Options: (a) let the container be the sole user
> of that credential, or (b) mint a separate login for the container.

## Configure and run

```sh
cd docker
cp .env.example .env    # then edit: API_KEY, CLAUDE_CREDENTIALS_JSON, TRONBYT_URL, DEVICE_ID
docker compose pull
docker compose up -d
docker compose logs -f
```

On `up`, the container seeds/reads the credential, starts fetching, and pushes a
frame every `PUSH_INTERVAL` seconds.

## How it works inside the container

One process (`serve_usage.py --push`) runs three things together:

- **Refresh + fetch (background thread):** on first boot, if
  `/config/credentials.json` is missing, it's seeded from `CLAUDE_CREDENTIALS_JSON`.
  The token is read from that file; within 5 minutes of expiry (or on a
  `401`/`403`) it does a `refresh_token` grant against `platform.claude.com`
  (falling back to `console.anthropic.com`) and **writes the rotated tokens
  back** atomically. A dead token (`invalid_grant`) triggers one reseed from
  `CLAUDE_CREDENTIALS_JSON` and retry.
- **Serve (background thread):** the latest usage JSON is served on
  `127.0.0.1:8377` so `pixlet` can fetch it — localhost only, not exposed.
- **Render + push (main loop):** every `PUSH_INTERVAL` seconds it renders
  `claude_usage.star` against that localhost URL and POSTs the frame to the
  tronbyt-server. Render/push errors are logged as `push failed` and the loop
  continues (the Tidbyt keeps showing the last good frame).

### The known risk

Headless OAuth refresh is not officially supported. There are community reports
([anthropics/claude-code #38248](https://github.com/anthropics/claude-code/issues/38248))
of the `refresh_token` grant returning **persistent `429`** for scheduled /
headless accounts, whose only documented recovery is an interactive
`claude login` — which this container can't do on its own. If that happens
here, the display goes stale and you'll need to paste a fresh
`CLAUDE_CREDENTIALS_JSON` value from a freshly-logged-in Claude Code. If you want
to know whether it affects your account before relying on this, run it for a few
hours and watch for `429`.

## Configuration reference

Set in `docker/.env` (see `.env.example`):

| Variable                  | Meaning                                          | Default       |
|---------------------------|--------------------------------------------------|---------------|
| `TRONBYT_URL`             | tronbyt-server base URL                          | —             |
| `DEVICE_ID`               | target device id                                 | —             |
| `API_KEY`                 | device API key (secret)                          | —             |
| `CLAUDE_OAUTH_TOKEN`      | **preferred** — long-lived token from `claude setup-token` (secret) | — |
| `CLAUDE_CREDENTIALS_JSON` | fallback credential blob, seeds the volume (secret)| —            |
| `INSTALL_ID`              | installation id in the device's app rotation     | `claudeusage` |
| `PUSH_INTERVAL`           | seconds between renders/pushes                    | `60`          |

**Prefer `CLAUDE_OAUTH_TOKEN`.** Mint one on a machine where you're logged in:

```bash
claude setup-token          # prints a long-lived token
```

Put it in `.env` as `CLAUDE_OAUTH_TOKEN=` and leave `CLAUDE_CREDENTIALS_JSON`
empty. The companion then uses that token verbatim and **never refreshes**, so
the refresh grant — which is rate limited in practice, returning HTTP 429 for any
request from a throttled IP regardless of whether the token is valid — is never
in the path. It also removes the token-rotation conflict with a Mac running
Claude Code, since nothing rotates. If that token is ever revoked you get a clear
`401`/`403` in the logs telling you to mint a new one, rather than a retry loop.

`CLAUDE_CREDENTIALS_JSON` remains supported for the refresh-based mode. Its
rotating credential lives in the `claude-creds` named volume (mounted at
`/config`); Docker manages it. A newer value pasted into `.env` is adopted on the
next start without a refresh; `docker compose down -v` forces a clean re-seed.

Build-time (in `Dockerfile`, override with `--build-arg`):

| Arg              | Meaning                     | Default  |
|------------------|-----------------------------|----------|
| `PIXLET_VERSION` | pixlet release to install   | `0.34.0` |
| `TARGETARCH`     | `arm64` (Pi) or `amd64` (PC)| `arm64`  |

`docker/.env` is git-ignored — keep the API key and credential out of the repo.

## Troubleshooting

- **Display reads `STALE <age>` with a reason (`RATE LIMIT` / `AUTH DEAD`)** —
  the last successful fetch is older than 15 minutes, so the app hides the
  percentages rather than showing a frozen reading. An amber border instead means
  only a few minutes behind. The companion reports its own staleness in the
  served JSON under `_companion`; `curl 127.0.0.1:8377/usage.json` shows it.
- **Logs show a `429` refresh error** — the refresh grant was rate-limited (see
  "known risk"). The companion backs off on consecutive failures (1m → 5m → 15m
  → 30m → 1h, honoring `Retry-After`) rather than retrying every fetch tick, so
  it stops adding to the throttle. To recover now, paste a fresh
  `CLAUDE_CREDENTIALS_JSON` and `docker compose up -d`.
- **`refresh token rejected` / `invalid_grant`** — the stored token is dead,
  usually rotated elsewhere (e.g. your Mac's Claude Code). Paste a current value
  into `.env` and `docker compose up -d`; it reseeds from it automatically.
- **`push failed` in the logs** — check `TRONBYT_URL`/`DEVICE_ID`/`API_KEY` and
  that the host can reach the tronbyt-server. A one-off `push failed` right at
  startup is harmless (the first render can race the first fetch); it self-heals
  on the next cycle.
- **Wrong architecture** (`no matching manifest` / `exec format error`) — the
  host is `amd64`; this image is `arm64`. Rebuild with
  `--build-arg TARGETARCH=amd64`.
