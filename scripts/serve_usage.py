#!/usr/bin/env python3
"""Companion server: republishes Claude usage limits for the Tronbyt app.

Reads the Claude Code OAuth access token from the macOS Keychain (Claude
Code keeps it fresh), fetches https://api.anthropic.com/api/oauth/usage on
an interval, and serves the last good response verbatim at /usage.json.

Point the Tronbyt app's "Data URL" config at http://<this-mac>:<port>/usage.json.

Stdlib only. Run it manually, or install as a launchd agent to keep it
running (see README).
"""

import argparse
import json
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

_state = {"body": None, "fetched_at": 0.0, "last_error": None}
_lock = threading.Lock()


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


def fetch_usage():
    """Fetch the usage endpoint. Returns (status, body_str)."""
    token = keychain_access_token()
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
        except Exception as e:  # keep the loop alive on keychain/network hiccups
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
        help="Interface to listen on. Use 0.0.0.0 so a tronbyt-server on "
        "another box can reach it (serves only usage percentages).",
    )
    parser.add_argument("--interval", type=int, default=120, help="Fetch interval in seconds.")
    args = parser.parse_args()

    threading.Thread(target=fetch_loop, args=(args.interval,), daemon=True).start()
    server = ThreadingHTTPServer((args.bind, args.port), Handler)
    print("Serving http://%s:%d/usage.json (fetching every %ds)" % (args.bind, args.port, args.interval))
    server.serve_forever()


if __name__ == "__main__":
    main()
