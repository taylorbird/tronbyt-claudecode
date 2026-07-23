# Usage endpoint — verified response shape

> **Revision note (2026-07-22):** the app no longer calls this endpoint or
> does OAuth itself. Anthropic's token-exchange endpoint persistently 429s
> (community-wide; see opencode#18329), so auth moved to a companion server
> (`scripts/serve_usage.py`) that reads Claude Code's own Keychain
> credentials and republishes the usage JSON verbatim. Everything below
> about the response shape still applies — the app parses the same JSON.

Verified 2026-07-21 with a live call (Claude Code access token from the macOS
Keychain). `GET https://api.anthropic.com/api/oauth/usage` with headers
`Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`,
`User-Agent: claude-code/2.1.9` → **HTTP 200**.

Response (token redacted, verbatim otherwise):

```json
{
  "five_hour": {"utilization": 47.0, "resets_at": "2026-07-21T23:29:59.538465+00:00", "limit_dollars": null, "used_dollars": null, "remaining_dollars": null},
  "seven_day": {"utilization": 13.0, "resets_at": "2026-07-27T16:59:59.538484+00:00", "limit_dollars": null, "used_dollars": null, "remaining_dollars": null},
  "seven_day_oauth_apps": null,
  "seven_day_opus": null,
  "seven_day_sonnet": null,
  "seven_day_cowork": null,
  "seven_day_omelette": null,
  "tangelo": null,
  "iguana_necktie": null,
  "omelette_promotional": null,
  "nimbus_quill": null,
  "cinder_cove": null,
  "amber_ladder": null,
  "extra_usage": {"is_enabled": true, "monthly_limit": null, "used_credits": 20847.0, "utilization": null, "currency": "USD", "decimal_places": 2, "disabled_reason": null, "daily": null, "weekly": null},
  "limits": [
    {"kind": "session", "group": "session", "percent": 47, "severity": "normal", "resets_at": "2026-07-21T23:29:59.538465+00:00", "scope": null, "is_active": true},
    {"kind": "weekly_all", "group": "weekly", "percent": 13, "severity": "normal", "resets_at": "2026-07-27T16:59:59.538484+00:00", "scope": null, "is_active": false},
    {"kind": "weekly_scoped", "group": "weekly", "percent": 14, "severity": "normal", "resets_at": "2026-07-27T16:59:59.538712+00:00", "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": false}
  ],
  "spend": {"used": {"amount_minor": 20847, "currency": "USD", "exponent": 2}, "limit": null, "percent": 0, "severity": "normal", "enabled": true, "disabled_reason": null, "cap": null, "balance": null, "auto_reload": null, "disclaimer": "...", "can_purchase_credits": false, "can_toggle": false},
  "member_dashboard_available": false
}
```

## Implications for the app (deviations from the design doc's assumptions)

1. **Use the `limits` array as the primary source**, not the top-level
   `five_hour`/`seven_day` objects. Each entry has `kind`, `group`,
   integer `percent`, `resets_at`, and optional `scope.model.display_name`.
   Kinds observed: `session`, `weekly_all`, `weekly_scoped` (model-scoped,
   e.g. "Fable" — this generalizes the design's "Opus ring").
   Fall back to `five_hour`/`seven_day` only if `limits` is absent.
2. **`seven_day_opus` and friends are present-but-null** — any key-presence
   check must also check for null.
3. `utilization` is a **float** at the top level; `percent` in `limits` is an
   **int**.
4. `resets_at` is ISO8601 with microseconds and a `+00:00` offset (not `Z`).
5. Ring labels: `session` → `5H`, `weekly_all` → `WK`, `weekly_scoped` →
   first two letters of `scope.model.display_name`, uppercased (e.g. `FA`).

## Open items to verify against live behavior

- **Refresh-token rotation semantics** (unverified): if Anthropic invalidates
  the previous refresh token on rotation, then losing the pixlet cache after
  the first rotation strands auth (config token already superseded) and the
  user must re-run `scripts/get_token.py`. During the live run, refresh twice
  with the same token to observe whether the old one stays valid.
- **Cache scoping** (unverified): if tronbyt-server shares `cache.star` state
  across installations of the same app, two installs with different accounts
  would collide on the fixed cache keys. Single-install deployments are
  unaffected. If multi-install matters later, suffix keys with a hash of the
  configured refresh token.

## Token types

- Claude Code **access token** (from Keychain `Claude Code-credentials`):
  works — HTTP 200. But it expires and rotates; not suitable for app config.
- **`claude setup-token` long-lived token (`sk-ant-oat01-…`)**: does NOT
  work — HTTP 403, `permission_error: OAuth token does not meet scope
  requirement user:profile` (verified 2026-07-22). The app therefore uses the
  fallback auth path from the design doc: `scripts/get_token.py` performs a
  one-time PKCE login requesting the `user:profile` scope on a separate grant,
  and the app refreshes the access token in Starlark, persisting rotated
  tokens via cache.
