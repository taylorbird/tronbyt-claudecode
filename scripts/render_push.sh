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
set -eu

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DATA_URL="${DATA_URL:-http://127.0.0.1:8377/usage.json}"
INSTALL_ID="${INSTALL_ID:-claudeusage}"
OUT="$(mktemp /tmp/claude_usage_push.XXXXXX).webp"
trap 'rm -f "$OUT"' EXIT

/opt/homebrew/bin/pixlet render "$REPO/claude_usage.star" data_url="$DATA_URL" -o "$OUT" >/dev/null

/usr/bin/curl -fsS -m 15 -X POST "$TRONBYT_URL/v0/devices/$DEVICE_ID/push" \
    --header "Authorization: $API_KEY" \
    --header 'Content-Type: application/json' \
    --data '{"image": "'"$(/usr/bin/base64 -i "$OUT")"'", "installationID": "'"$INSTALL_ID"'"}' \
    >/dev/null
