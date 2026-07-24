# Docker deployment (off-Mac, e.g. a Raspberry Pi)

Runs the whole updater in Docker so nothing has to run on your Mac: a
**companion** that fetches Claude usage (refreshing its own OAuth token) and a
**pusher** that renders `claude_usage.star` and pushes frames to the
tronbyt-server. Designed for a box on the same LAN as the tronbyt-server (the
push model needs only outbound connections; see the top-level README).

```
credentials.json ──> companion (fetch + refresh + write-back) ──> :8377/usage.json
                                                                        │
                              pusher (pixlet render → POST /push) <──────┘ ──> tronbyt-server
```

## What you need first

- Docker + Docker Compose on the host (a 64-bit Raspberry Pi OS is `arm64`,
  which the image targets by default).
- Network reachability from the host to the tronbyt-server
  (`http://10.33.103.126:8100`).
- A tronbyt device **API key** (tronbyt web UI → your device).
- A Claude **`credentials.json`** — the one genuinely manual step, below.

## The one manual step: seed `credentials.json`

Off the Mac there is no Claude Code process keeping a token fresh, so the
companion refreshes the OAuth token itself. It needs a starting credential that
contains a **refresh token**. You do **not** run any OAuth login flow yourself
(that PKCE token-exchange step is the one that rate-limits with `429`); instead
you copy the credential a logged-in Claude Code already holds.

**From a Mac running Claude Code** — export the Keychain item to a file:

```sh
security find-generic-password -s "Claude Code-credentials" -w > credentials.json
```

**From a Linux box running Claude Code** — it is already a file:

```sh
cp ~/.claude/.credentials.json credentials.json
```

Either way the file looks like `{"claudeAiOauth":{"accessToken":"...",
"refreshToken":"...","expiresAt":<ms>, ...}}`. Put it here:

```sh
mkdir -p docker/creds
mv credentials.json docker/creds/credentials.json
```

> **Important — don't share one refresh token between two active loggers.**
> Refresh tokens **rotate on every use**. If your Mac's Claude Code *and* this
> container both refresh the *same* token, they invalidate each other's copy
> and one of them gets logged out. Options: (a) let the container be the sole
> user of that credential, or (b) mint a separate login for the container.
> `docker/creds/` is a writable volume so the container can persist each
> rotated token across restarts.

## Configure and run

```sh
cd docker
cp .env.example .env          # then edit: API_KEY, and confirm TRONBYT_URL / DEVICE_ID
docker compose up -d --build
```

That's it. On `up`, the companion reads the seeded credentials and starts
serving usage; the pusher renders and pushes a frame every `PUSH_INTERVAL`
seconds.

Check it:

```sh
docker compose logs -f            # both services
docker compose exec companion \
    python3 -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8377/usage.json').read().decode())"
```

## How auth works inside the container

- The companion reads `accessToken` / `expiresAt` from
  `/creds/credentials.json`. While the access token is still valid it is used
  as-is.
- Within 5 minutes of expiry (or on a `401`/`403` from the usage endpoint) the
  companion does a `refresh_token` grant against `platform.claude.com`
  (falling back to `console.anthropic.com`), then **writes the rotated tokens
  back** to `/creds/credentials.json` atomically (temp file + rename, `0600`).
- The Tronbyt keeps showing the last good numbers (with the amber "stale"
  pixel) through short fetch failures.

### The known risk

Headless OAuth refresh is not officially supported. There are community reports
([anthropics/claude-code #38248](https://github.com/anthropics/claude-code/issues/38248))
of the `refresh_token` grant returning **persistent `429`** for scheduled /
headless accounts, whose only documented recovery is an interactive
`claude login` — which this container can't do on its own. If that happens
here, the display goes stale and you'll need to re-seed `credentials.json` from
a freshly-logged-in Claude Code. If you want to know whether it affects your
account before relying on this, run a short refresh test with your real token
first.

## Configuration reference

Set in `docker/.env` (see `.env.example`):

| Variable        | Meaning                                          | Default       |
|-----------------|--------------------------------------------------|---------------|
| `TRONBYT_URL`   | tronbyt-server base URL                          | —             |
| `DEVICE_ID`     | target device id                                 | —             |
| `API_KEY`       | device API key (secret)                          | —             |
| `INSTALL_ID`    | installation id in the device's app rotation     | `claudeusage` |
| `PUSH_INTERVAL` | seconds between pushes                            | `60`          |

Build-time (in `Dockerfile`, override with `--build-arg`):

| Arg              | Meaning                     | Default  |
|------------------|-----------------------------|----------|
| `PIXLET_VERSION` | pixlet release to install   | `0.34.0` |
| `TARGETARCH`     | `arm64` (Pi) or `amd64` (PC)| `arm64`  |

`docker/.env` and `docker/creds/` are git-ignored — keep the API key and
credentials out of the repo.

## Troubleshooting

- **`/usage.json` returns 503 with a `429` refresh error** — the refresh grant
  was rate-limited (see "known risk"). Re-seed `credentials.json`.
- **503 with `refresh token rejected`** — the stored refresh token is dead
  (`invalid_grant`), usually because it was rotated elsewhere (e.g. your Mac's
  Claude Code). Re-seed from a current login.
- **pusher logs `push failed`** — check `TRONBYT_URL`/`DEVICE_ID`/`API_KEY` and
  that the host can reach the tronbyt-server.
- **Wrong architecture** — building on the Pi picks `arm64` automatically; to
  build for a PC pass `--build-arg TARGETARCH=amd64`.
