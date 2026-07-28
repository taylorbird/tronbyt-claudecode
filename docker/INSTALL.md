# Install guide (start here if you've never used Docker)

This walks you through running the Claude-usage updater on a computer using
**Docker Compose** — a tool that starts pre-built programs ("containers") from a
short config file, so you don't install Python, pixlet, or anything else by
hand. There are **no files to transfer**: you paste two secrets into a settings
file and run two commands.

**What it does once running:** it fetches your Claude usage numbers and pushes a
picture of them to your Tidbyt every minute, without needing your Mac to be on.

---

## Before you start

- **A 64-bit computer to run it on** — a Raspberry Pi (64-bit Raspberry Pi OS)
  or an Apple-Silicon Mac. The published image is built for `arm64`. If your
  computer is an Intel/AMD PC (`amd64`), stop and ask for a multi-arch image
  first — this one won't run there.
- **Your Mac**, where Claude Code is logged in — you'll copy one value from it.
- Both computers on the same network as the tronbyt-server.

---

## Step 1 — Install Docker on the computer that will run this

On a Raspberry Pi / Linux, the official one-line installer is easiest. Run these
on the Pi:

```
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
```

Log out and back in (so the second command takes effect), then check it works:

```
docker version
docker compose version
```

Both should print version numbers. (On a Mac, install **Docker Desktop**
instead and make sure it's running.)

> "Docker Compose" is built into modern Docker as `docker compose` (two words).
> If you only have the older `docker-compose` (one word), use that spelling
> everywhere below.

---

## Step 2 — Copy your Claude credential value (on your Mac)

The container needs the OAuth token Claude Code already created when you logged
into it. **You are not making a new login** — you're copying the existing one.

On your **Mac**, run:

```
security find-generic-password -s "Claude Code-credentials" -w
```

It prints one line that looks like `{"claudeAiOauth":{"accessToken":"…","refreshToken":"…",…}}`.
**Select and copy that entire line.** You'll paste it in Step 4. Treat it like a
password — it's your account token.

(If the computer running the container is itself a Linux box with Claude Code
logged in, you can instead copy the contents of `~/.claude/.credentials.json`.)

---

## Step 3 — Make a folder and get the two config files

On the computer that will run this:

```
mkdir -p ~/claude-usage
cd ~/claude-usage
```

You need two files here — **just text files, no credential file to move**:

1. **`docker-compose.yml`** — copy it from this repo's `docker/` folder onto the
   machine (via `scp`, a USB stick, or by pasting it into an editor). If copying
   from your Mac over SSH:
   ```
   scp docker/docker-compose.yml <host>:~/claude-usage/docker-compose.yml
   ```
2. **`.env`** — you'll create this next.

---

## Step 4 — Create the `.env` settings file

In `~/claude-usage/`, make a file named `.env`. Paste your real values in —
including the credential line you copied in Step 2:

```
TRONBYT_URL=http://YOUR-TRONBYT-SERVER:8100
DEVICE_ID=your-device-id
API_KEY=paste-your-device-api-key-here
CLAUDE_CREDENTIALS_JSON=paste-the-whole-{"claudeAiOauth":{...}}-line-here
INSTALL_ID=claudeusage
PUSH_INTERVAL=60
```

What each line means:

| Setting                   | What to put                                                            |
|---------------------------|------------------------------------------------------------------------|
| `TRONBYT_URL`             | Your tronbyt-server address.                                           |
| `DEVICE_ID`               | Your Tidbyt device id.                                                 |
| `API_KEY`                 | Your device's API key (secret). On your Mac it's in `~/Library/LaunchAgents/com.tbird.claude-usage-push.plist`. |
| `CLAUDE_CREDENTIALS_JSON` | The whole line you copied in Step 2 (secret).                          |
| `INSTALL_ID`              | Leave as `claudeusage` unless you know you need something else.        |
| `PUSH_INTERVAL`           | Seconds between updates. `60` is fine.                                 |

Put the credential all on **one line** (the command in Step 2 already prints it
as one line). No quotes needed.

---

## Step 5 — Start it

From `~/claude-usage/`:

```
docker compose pull      # downloads the app image
docker compose up -d      # starts it in the background
```

That's it. On first start the container reads `CLAUDE_CREDENTIALS_JSON`, saves it
into its own storage (a Docker-managed volume — nothing for you to create), and
from then on keeps the token fresh there on its own.

---

## Step 6 — Check that it's working

Watch the logs:

```
docker compose logs -f
```

You should see two startup lines — `Serving http://127.0.0.1:8377/usage.json ...`
and `Pushing to http://… (device …) every 60s …` — and then no errors. Your
Tidbyt should show the usage rings within a minute. (A single `push failed`
right at startup is harmless — the first render can beat the first data fetch;
it fixes itself on the next cycle.)

Press `Ctrl+C` to stop watching (this does **not** stop the app).

---

## Everyday commands

Run these from `~/claude-usage/`:

| Task                        | Command                                            |
|-----------------------------|----------------------------------------------------|
| See logs                    | `docker compose logs -f`                           |
| Stop it                     | `docker compose down`                              |
| Start it again              | `docker compose up -d`                             |
| Update to a newer image     | `docker compose pull` then `docker compose up -d`  |
| See if it's running         | `docker compose ps`                                |

---

## Troubleshooting

- **`no matching manifest` / `exec format error`** — the computer is `amd64`;
  this image is `arm64`. Ask for a multi-arch image.
- **Logs show a `429` refresh error and the display goes stale** — the token
  refresh was rate-limited (a known, unresolved Anthropic issue for headless
  refresh). Get a fresh value (Step 2), update `CLAUDE_CREDENTIALS_JSON` in
  `.env`, and run `docker compose up -d` again.
- **`refresh token rejected` / `invalid_grant`** — the token was rotated
  somewhere else (for example your Mac's Claude Code used it). Do the same
  recovery: paste a fresh value into `.env` and `docker compose up -d`. The
  container automatically falls back to the `.env` value when its stored token
  is dead.
- **`push failed` in the logs** — check `TRONBYT_URL`, `DEVICE_ID`, and
  `API_KEY` in `.env`, and that this computer can reach the tronbyt-server.

> **Heads-up on sharing the token:** the credential you copied is the same one
> your Mac's Claude Code uses, and it rotates as it's used. Over time the Mac and
> this container can invalidate each other, forcing you to re-copy (Step 2).
> Fine for getting started; for a permanent setup, give this computer its own
> Claude login instead of sharing the Mac's.
