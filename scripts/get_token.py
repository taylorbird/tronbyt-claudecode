#!/usr/bin/env python3
"""One-time interactive OAuth PKCE login for the Claude usage Tronbyt app.

Opens (or prints) a claude.ai authorize URL, then exchanges the pasted code
for tokens. The REFRESH TOKEN it prints is what goes into the app's
"Refresh token" config field; the app refreshes access tokens on its own.

Stdlib only. Endpoint details are community-documented, so on any HTTP
error this script prints the full status and response body for debugging.
"""

import argparse
import base64
import hashlib
import json
import secrets
import sys
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

# Claude Code's public OAuth client id (PKCE public client, no secret).
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
REDIRECT_URI = "https://console.anthropic.com/oauth/code/callback"
SCOPE = "user:profile"
AUTHORIZE_URL = "https://claude.ai/oauth/authorize"
# Community docs disagree on which token endpoint is current; try in order.
TOKEN_URLS = [
    "https://console.anthropic.com/v1/oauth/token",
    "https://platform.claude.com/v1/oauth/token",
]


def b64url(data):
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


def make_pkce():
    """Return (verifier, S256 challenge). Verifier is 43-128 urlsafe chars."""
    verifier = b64url(secrets.token_bytes(64))  # 86 chars
    challenge = b64url(hashlib.sha256(verifier.encode("ascii")).digest())
    return verifier, challenge


def build_authorize_url(scope, challenge, state):
    params = {
        "code": "true",
        "client_id": CLIENT_ID,
        "response_type": "code",
        "redirect_uri": REDIRECT_URI,
        "scope": scope,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
    }
    return AUTHORIZE_URL + "?" + urllib.parse.urlencode(params)


def read_pasted_code(our_state):
    """Read the code shown after approval. Usually 'code#state'."""
    raw = input("Paste the code shown after approving: ").strip()
    if not raw:
        sys.exit("No code entered; aborting.")
    if "#" in raw:
        code, state = raw.split("#", 1)
        return code, state
    return raw, our_state


def post_json(url, payload):
    """POST JSON; return (status, parsed-or-raw body). Never raises on HTTP errors."""
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode("utf-8", "replace")
            status = resp.status
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        status = e.code
    except urllib.error.URLError as e:
        return None, str(e.reason)
    try:
        return status, json.loads(body)
    except ValueError:
        return status, body


def exchange_code(code, state, verifier):
    """Try each token URL in order; return the first successful token response."""
    payload = {
        "grant_type": "authorization_code",
        "code": code,
        "state": state,
        "client_id": CLIENT_ID,
        "redirect_uri": REDIRECT_URI,
        "code_verifier": verifier,
    }
    for url in TOKEN_URLS:
        print("Exchanging code at %s ..." % url)
        status, body = post_json(url, payload)
        if status == 200 and isinstance(body, dict):
            return body
        print("  FAILED: HTTP %s" % status)
        print("  Response body: %s" % (json.dumps(body) if isinstance(body, dict) else body))
    sys.exit("Token exchange failed at all endpoints (see bodies above).")


def print_tokens(tokens):
    print()
    print("=" * 60)
    print("REFRESH TOKEN (put this in the Tronbyt app config):")
    print("  %s" % tokens.get("refresh_token", "<none returned!>"))
    print()
    print("Access token (short-lived, for manual testing):")
    print("  %s" % tokens.get("access_token", "<none returned!>"))
    print()
    print("expires_in: %s" % tokens.get("expires_in", "<absent>"))
    if "scope" in tokens:
        print("scope: %s" % tokens["scope"])
    print("=" * 60)
    print("The refresh token is a SECRET tied to your Claude account -- do not share or commit it.")


def main():
    parser = argparse.ArgumentParser(
        description="One-time Claude OAuth PKCE login; prints the refresh token "
        "for the Tronbyt claude_usage app."
    )
    parser.add_argument(
        "--scope",
        default=SCOPE,
        help='OAuth scope(s) to request (default: "%(default)s"). If the browser '
        'shows a scope error, retry with e.g. '
        '--scope "org:create_api_key user:profile user:inference".',
    )
    args = parser.parse_args()

    verifier, challenge = make_pkce()
    state = b64url(secrets.token_bytes(32))
    url = build_authorize_url(args.scope, challenge, state)

    print("Open this URL in your browser and approve access:")
    print()
    print(url)
    print()
    try:
        webbrowser.open(url)
    except Exception:
        pass

    code, returned_state = read_pasted_code(state)
    tokens = exchange_code(code, returned_state, verifier)
    print_tokens(tokens)


if __name__ == "__main__":
    main()
