"""Claude subscription usage limits as radial gauges."""

load("cache.star", "cache")
load("encoding/json.star", "json")
load("http.star", "http")
load("render.star", "render")
load("schema.star", "schema")

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
USER_AGENT = "claude-code/2.1.9"
LAST_GOOD_KEY = "claude_usage_last_good"

def mock_usage(session_pct, weekly_pct, scoped = None):
    limits = [
        {"kind": "session", "group": "session", "percent": session_pct, "severity": "normal", "resets_at": "2026-07-22T20:00:00+00:00", "scope": None, "is_active": True},
        {"kind": "weekly_all", "group": "weekly", "percent": weekly_pct, "severity": "normal", "resets_at": "2026-07-27T17:00:00+00:00", "scope": None, "is_active": False},
    ]
    if scoped != None:
        limits.append({"kind": "weekly_scoped", "group": "weekly", "percent": scoped, "severity": "normal", "resets_at": "2026-07-27T17:00:00+00:00", "scope": {"model": {"id": None, "display_name": "Fable"}, "surface": None}, "is_active": False})
    return {
        "five_hour": {"utilization": session_pct * 1.0, "resets_at": "2026-07-22T20:00:00+00:00"},
        "seven_day": {"utilization": weekly_pct * 1.0, "resets_at": "2026-07-27T17:00:00+00:00"},
        "seven_day_opus": None,
        "limits": limits,
    }

MOCKS = {
    "happy": mock_usage(62, 31),
    "high": mock_usage(95, 83),
    "zero": mock_usage(0, 0),
    "scoped": mock_usage(62, 31, scoped = 12),
}

# returns (usage dict or None, is_stale, error string or None)
def get_usage(config):
    mock = config.str("dev_mock")
    if mock == "expired":
        return None, False, "expired"
    if mock == "outage":
        cached = cache.get(LAST_GOOD_KEY)
        if cached:
            return json.decode(cached), True, None
        return None, False, "no data"
    if mock:
        return MOCKS[mock], False, None

    token = config.str("token")
    if not token:
        return None, False, "setup"

    res = http.get(
        USAGE_URL,
        headers = {
            "Authorization": "Bearer " + token,
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": USER_AGENT,
        },
        ttl_seconds = 120,
    )
    if res.status_code == 200:
        cache.set(LAST_GOOD_KEY, res.body(), ttl_seconds = 86400)
        return json.decode(res.body()), False, None
    if res.status_code in (401, 403):
        return None, False, "expired"
    cached = cache.get(LAST_GOOD_KEY)
    if cached:
        return json.decode(cached), True, None
    return None, False, "http %d" % res.status_code

def main(config):
    # _stale is unused in this temporary main; Task 5's ring layout consumes it.
    usage, _stale, err = get_usage(config)
    if err:
        return render.Root(child = render.Text(err))
    return render.Root(child = render.Text("5H %d WK %d" % (
        int(usage["five_hour"]["utilization"]),
        int(usage["seven_day"]["utilization"]),
    )))

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "token",
                name = "OAuth token",
                desc = "Token from `claude setup-token` (sk-ant-oat01-...)",
                icon = "key",
            ),
            schema.Toggle(
                id = "show_reset",
                name = "Show reset countdown",
                desc = "Top row shows time until the tightest limit resets",
                icon = "clock",
                default = True,
            ),
        ],
    )
