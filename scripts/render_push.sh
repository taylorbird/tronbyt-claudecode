#!/bin/sh
# Render claude_usage.star locally and push the frame to a tronbyt-server.
#
# Required environment (pass via launchd plist or shell — keep the API key
# out of this repo):
#   TRONBYT_URL   e.g. http://10.33.103.126:8100
#   DEVICE_ID     tronbyt device id
#   API_KEY       tronbyt device API key
# Optional:
#   DATA_URL      companion usage.json (default http://127.0.0.1:8377/usage.json)
#   INSTALL_ID    installation id in the rotation (default claudeusage)
#   PIXLET_BIN    path to the pixlet binary (default /opt/homebrew/bin/pixlet;
#                 the Docker image sets this to /usr/local/bin/pixlet)
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DATA_URL="${DATA_URL:-http://127.0.0.1:8377/usage.json}"
INSTALL_ID="${INSTALL_ID:-claudeusage}"
PIXLET_BIN="${PIXLET_BIN:-/opt/homebrew/bin/pixlet}"
OUT="$(mktemp /tmp/claude_usage_push.XXXXXX).webp"
trap 'rm -f "$OUT"' EXIT

"$PIXLET_BIN" render "$REPO/claude_usage.star" data_url="$DATA_URL" -o "$OUT" >/dev/null

# base64: read via stdin and strip newlines so it works the same on macOS
# (BSD) and Linux (GNU, which wraps at 76 cols) base64.
IMG="$(/usr/bin/base64 < "$OUT" | /usr/bin/tr -d '\n')"

/usr/bin/curl -fsS -m 15 -X POST "$TRONBYT_URL/v0/devices/$DEVICE_ID/push" \
    --header "Authorization: $API_KEY" \
    --header 'Content-Type: application/json' \
    --data '{"image": "'"$IMG"'", "installationID": "'"$INSTALL_ID"'"}' \
    >/dev/null
