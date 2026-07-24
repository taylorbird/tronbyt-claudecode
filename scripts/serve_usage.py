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


def refresh_tokens(path):
    """Exchange the stored refresh token for a fresh access token, persist the
    rotated tokens, and return the new access token. Raises on failure."""
    with _creds_lock:
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
                # 400 invalid_grant => the refresh token is dead; trying the
                # other endpoint won't help and re-login is required.
                if e.code == 400:
                    raise RuntimeError("refresh token rejected: %s" % last_err)
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


def file_access_token(path):
    """Return a valid access token from the creds file, refreshing if the
    stored token is missing or within REFRESH_MARGIN of expiry."""
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
        help="Path to a Claude .credentials.json. When set, the companion "
        "reads/refreshes the OAuth token from this file (and writes rotated "
        "tokens back) instead of the macOS Keychain. Use off-Mac.",
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
    server.serve_forever()


if __name__ == "__main__":
    main()
