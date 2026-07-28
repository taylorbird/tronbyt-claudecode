#!/usr/bin/env python3
"""Companion server: republishes Claude usage limits for the Tronbyt app.

Fetches https://api.anthropic.com/api/oauth/usage on an interval and serves
the last good response verbatim at /usage.json. Point the Tronbyt app's
"Data URL" config (or render_push.sh's DATA_URL) at
http://<this-host>:<port>/usage.json.

Two credential sources:

  * macOS Keychain (default): reads Claude Code's OAuth access token from the
    "Claude Code-credentials" item. Claude Code keeps that token fresh, so the
    companion never has to refresh. Use this on a Mac where you run Claude Code.

  * Credentials file (--creds-file): reads a .credentials.json holding an
    OAuth access + refresh token, refreshes the access token itself when it is
    near expiry, and writes the rotated tokens back to the file. Use this off
    the Mac (e.g. in the Docker/Pi deployment) where no Claude Code process is
    around to keep the token fresh. Seed the file once from a logged-in
    Claude Code (see docker/README.md).

Stdlib only. Run it manually, or install as a launchd agent / container to
keep it running (see README).
"""

import argparse
import base64
import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
USER_AGENT = "claude-code/2.1.9"
KEYCHAIN_SERVICE = "Claude Code-credentials"

# OAuth refresh (credentials-file mode). Same public PKCE client id Claude Code
# uses. The token endpoint moved to platform.claude.com; console.anthropic.com
# is kept as a fallback. Refresh tokens ROTATE on use, so each successful
# refresh must be written back or the next one fails with 400 invalid_grant.
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
TOKEN_URLS = [
    "https://platform.claude.com/v1/oauth/token",
    "https://console.anthropic.com/v1/oauth/token",
]
# Refresh this many seconds before the access token's stated expiry.
REFRESH_MARGIN = 300

# Optional env var holding the initial credentials JSON (same shape as the
# file). It SEEDS the writable creds file on first boot, so the credential can
# be passed in like any other config value instead of transferring a file. The
# living, rotated copy then lives in the (writable) --creds-file location.
CREDS_ENV = "CLAUDE_CREDENTIALS_JSON"

_state = {"body": None, "fetched_at": 0.0, "last_error": None}
_lock = threading.Lock()

# Set from --creds-file; None means Keychain mode. Guards refresh/write-back so
# only one fetch thread refreshes at a time.
_creds_file = None
_creds_lock = threading.Lock()


def keychain_access_token():
    """Read Claude Code's current access token from the macOS Keychain."""
    out = subprocess.run(
        ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        raise RuntimeError("keychain read failed: %s" % out.stderr.strip())
    creds = json.loads(out.stdout)
    return creds["claudeAiOauth"]["accessToken"]


def _load_creds(path):
    with open(path) as f:
        return json.load(f)


def _oauth_block(creds):
    """Support both {"claudeAiOauth": {...}} (Claude Code's shape) and a flat
    {"accessToken": ...} object. Returns the inner dict to read/mutate."""
    return creds.get("claudeAiOauth", creds)


def _save_creds(path, creds):
    """Write creds back atomically with 0600 perms (temp file + rename)."""
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(creds, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


class _InvalidGrant(Exception):
    """The refresh token was rejected (RFC 6749 invalid_grant) — it's dead."""


def _ensure_creds_file(path):
    """Make sure the writable creds file exists. If it doesn't, seed it from the
    CLAUDE_CREDENTIALS_JSON env var so the credential can be supplied without
    transferring a file. Raises if neither the file nor the env seed exists."""
    if os.path.exists(path):
        return
    seed = os.environ.get(CREDS_ENV)
    if not seed:
        raise RuntimeError(
            "no creds file at %s and %s is not set — provide one or the other" % (path, CREDS_ENV)
        )
    d = os.path.dirname(path)
    if d:
        os.makedirs(d, exist_ok=True)
    _save_creds(path, json.loads(seed))


def _do_refresh(path):
    """One refresh attempt against the stored token. Persists the rotated tokens
    and returns the new access token. Raises _InvalidGrant if the refresh token
    is dead, RuntimeError on other failures."""
    creds = _load_creds(path)
    oauth = _oauth_block(creds)
    rt = oauth.get("refreshToken")
    if not rt:
        raise RuntimeError("no refreshToken in %s" % path)
    payload = json.dumps(
        {"grant_type": "refresh_token", "refresh_token": rt, "client_id": CLIENT_ID}
    ).encode("utf-8")
    last_err = None
    for url in TOKEN_URLS:
        req = urllib.request.Request(
            url,
            data=payload,
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": USER_AGENT,
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                data = json.loads(resp.read().decode("utf-8", "replace"))
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", "replace")
            last_err = "HTTP %d: %s" % (e.code, body[:200])
            # invalid_grant => the refresh token is dead; trying the other
            # endpoint won't help. Signal so the caller can reseed from env.
            if e.code == 400 and "invalid_grant" in body:
                raise _InvalidGrant(last_err)
            continue
        except Exception as e:  # network hiccup: try the next endpoint
            last_err = str(e)
            continue

        oauth["accessToken"] = data["access_token"]
        if data.get("refresh_token"):
            oauth["refreshToken"] = data["refresh_token"]
        if data.get("expires_in"):
            oauth["expiresAt"] = int((time.time() + data["expires_in"]) * 1000)
        if "claudeAiOauth" in creds:
            creds["claudeAiOauth"] = oauth
        else:
            creds = oauth
        _save_creds(path, creds)
        return oauth["accessToken"]
    raise RuntimeError("token refresh failed at all endpoints: %s" % last_err)


def refresh_tokens(path):
    """Refresh and persist tokens. If the stored (rotated) refresh token is dead
    but CLAUDE_CREDENTIALS_JSON is set, reseed from that env value and retry once
    — so pasting a fresh token into the env and restarting is the recovery."""
    with _creds_lock:
        _ensure_creds_file(path)
        try:
            return _do_refresh(path)
        except _InvalidGrant as e:
            seed = os.environ.get(CREDS_ENV)
            if not seed:
                raise RuntimeError(
                    "refresh token rejected and %s not set to reseed: %s" % (CREDS_ENV, e)
                )
            _save_creds(path, json.loads(seed))
            try:
                return _do_refresh(path)
            except _InvalidGrant as e2:
                raise RuntimeError(
                    "refresh token rejected even after reseeding from %s "
                    "(paste a current token and restart): %s" % (CREDS_ENV, e2)
                )


def file_access_token(path):
    """Return a valid access token from the creds file, refreshing if the
    stored token is missing or within REFRESH_MARGIN of expiry."""
    _ensure_creds_file(path)
    oauth = _oauth_block(_load_creds(path))
    token = oauth.get("accessToken")
    expires_at = oauth.get("expiresAt")  # epoch milliseconds
    if token and expires_at and (expires_at / 1000.0) - time.time() > REFRESH_MARGIN:
        return token
    return refresh_tokens(path)


def access_token():
    if _creds_file:
        return file_access_token(_creds_file)
    return keychain_access_token()


def _request_usage(token):
    """One GET to the usage endpoint. Returns (status, body_str)."""
    req = urllib.request.Request(
        USAGE_URL,
        headers={
            "Authorization": "Bearer " + token,
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")


def fetch_usage():
    """Fetch the usage endpoint. Returns (status, body_str). In creds-file mode
    a 401/403 triggers one forced refresh + retry (the cached token may have
    expired between refreshes)."""
    status, body = _request_usage(access_token())
    if status in (401, 403) and _creds_file:
        status, body = _request_usage(refresh_tokens(_creds_file))
    return status, body


def fetch_loop(interval):
    while True:
        try:
            status, body = fetch_usage()
            with _lock:
                if status == 200:
                    _state["body"] = body
                    _state["fetched_at"] = time.time()
                    _state["last_error"] = None
                else:
                    _state["last_error"] = "HTTP %d: %s" % (status, body[:200])
            if status != 200:
                print("fetch failed: %s" % _state["last_error"], file=sys.stderr)
        except Exception as e:  # keep the loop alive on keychain/network/refresh hiccups
            with _lock:
                _state["last_error"] = str(e)
            print("fetch failed: %s" % e, file=sys.stderr)
        time.sleep(interval)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split("?")[0] != "/usage.json":
            self.send_error(404)
            return
        with _lock:
            body = _state["body"]
            age = time.time() - _state["fetched_at"]
            err = _state["last_error"]
        if body is None:
            self.send_response(503)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"error": err or "no data yet"}).encode())
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("X-Age-Seconds", str(int(age)))
        self.end_headers()
        self.wfile.write(body.encode("utf-8"))

    def log_message(self, fmt, *args):  # quiet per-request logging
        pass


def render_and_push(star_path, data_url, tronbyt_url, device_id, api_key, install_id, pixlet_bin):
    """Render the star against data_url and push the frame to the tronbyt-server.
    Raises on any failure (bad render or non-2xx push)."""
    out = "/tmp/claude_usage_frame.webp"
    try:
        subprocess.run(
            [pixlet_bin, "render", star_path, "data_url=" + data_url, "-o", out],
            check=True,
            capture_output=True,
            text=True,
        )
        with open(out, "rb") as f:
            img = base64.b64encode(f.read()).decode("ascii")
    finally:
        try:
            os.remove(out)
        except OSError:
            pass
    body = json.dumps({"image": img, "installationID": install_id}).encode("utf-8")
    req = urllib.request.Request(
        "%s/v0/devices/%s/push" % (tronbyt_url.rstrip("/"), device_id),
        data=body,
        method="POST",
        headers={"Authorization": api_key, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return resp.status


def push_loop(port, interval, star_path, tronbyt_url, device_id, api_key, install_id, pixlet_bin):
    """Render+push on a timer, reading usage from this same process's localhost
    HTTP server. Keeps looping across transient render/push failures."""
    data_url = "http://127.0.0.1:%d/usage.json" % port
    while True:
        try:
            render_and_push(star_path, data_url, tronbyt_url, device_id, api_key, install_id, pixlet_bin)
        except subprocess.CalledProcessError as e:
            print("push failed (render): %s" % (e.stderr or e).strip(), file=sys.stderr)
        except Exception as e:
            print("push failed: %s" % e, file=sys.stderr)
        time.sleep(interval)


def main():
    parser = argparse.ArgumentParser(description="Serve Claude usage JSON for the Tronbyt app.")
    parser.add_argument("--port", type=int, default=8377)
    parser.add_argument(
        "--bind",
        default="127.0.0.1",
        help="Interface to listen on. Use 0.0.0.0 so a tronbyt-server or the "
        "push container on another box can reach it (serves only usage percentages).",
    )
    parser.add_argument("--interval", type=int, default=120, help="Fetch interval in seconds.")
    parser.add_argument(
        "--creds-file",
        default=None,
        help="Path to a writable Claude .credentials.json. When set, the "
        "companion reads/refreshes the OAuth token from this file (and writes "
        "rotated tokens back) instead of the macOS Keychain. If the file does "
        "not exist it is seeded from the %s env var. Use off-Mac." % CREDS_ENV,
    )
    parser.add_argument(
        "--push",
        action="store_true",
        help="Also render claude_usage.star and push frames to the "
        "tronbyt-server from THIS process (one all-in-one container). Reads "
        "TRONBYT_URL, DEVICE_ID, API_KEY, and optionally INSTALL_ID / "
        "PUSH_INTERVAL / PIXLET_BIN / STAR_PATH from the environment.",
    )
    args = parser.parse_args()

    global _creds_file
    _creds_file = args.creds_file
    source = "creds file %s" % _creds_file if _creds_file else "macOS Keychain"

    threading.Thread(target=fetch_loop, args=(args.interval,), daemon=True).start()
    server = ThreadingHTTPServer((args.bind, args.port), Handler)
    print(
        "Serving http://%s:%d/usage.json (fetching every %ds via %s)"
        % (args.bind, args.port, args.interval, source)
    )

    if not args.push:
        server.serve_forever()
        return

    # All-in-one mode: serve on a background thread, render+push in the main
    # thread against our own localhost endpoint. No second container, no
    # internal network — the star still just fetches a URL (a local one).
    threading.Thread(target=server.serve_forever, daemon=True).start()
    here = os.path.dirname(os.path.abspath(__file__))
    star_path = os.environ.get("STAR_PATH", os.path.join(os.path.dirname(here), "claude_usage.star"))
    push_interval = int(os.environ.get("PUSH_INTERVAL", "60"))
    pixlet_bin = os.environ.get("PIXLET_BIN", "pixlet")
    try:
        tronbyt_url = os.environ["TRONBYT_URL"]
        device_id = os.environ["DEVICE_ID"]
        api_key = os.environ["API_KEY"]
    except KeyError as e:
        sys.exit("--push requires %s in the environment" % e)
    install_id = os.environ.get("INSTALL_ID", "claudeusage")
    print(
        "Pushing to %s (device %s) every %ds via %s"
        % (tronbyt_url, device_id, push_interval, pixlet_bin)
    )

    # Wait (up to ~30s) for the first successful fetch before the first push, so
    # a fresh start never flashes a "503 / no data yet" frame on the device. If
    # data never arrives (a genuine failure), fall through and push anyway so
    # real errors still reach the screen.
    ready = False
    for _ in range(30):
        with _lock:
            ready = _state["body"] is not None
        if ready:
            break
        time.sleep(1)
    print("first usage fetch %s; starting push loop" % ("ready" if ready else "timed out — pushing anyway"))

    push_loop(args.port, push_interval, star_path, tronbyt_url, device_id, api_key, install_id, pixlet_bin)


if __name__ == "__main__":
    main()
