"""Claude subscription usage limits as radial gauges."""

load("cache.star", "cache")
load("encoding/json.star", "json")
load("http.star", "http")
load("math.star", "math")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
USER_AGENT = "claude-code/2.1.9"
LAST_GOOD_KEY = "claude_usage_last_good"

def iso(t):
    return t.format("2006-01-02T15:04:05Z07:00")

def mock_usage(session_pct, weekly_pct, session_reset, weekly_reset, scoped = None):
    limits = [
        {"kind": "session", "group": "session", "percent": session_pct, "severity": "normal", "resets_at": session_reset, "scope": None, "is_active": True},
        {"kind": "weekly_all", "group": "weekly", "percent": weekly_pct, "severity": "normal", "resets_at": weekly_reset, "scope": None, "is_active": False},
    ]
    if scoped != None:
        limits.append({"kind": "weekly_scoped", "group": "weekly", "percent": scoped, "severity": "normal", "resets_at": weekly_reset, "scope": {"model": {"id": None, "display_name": "Fable"}, "surface": None}, "is_active": False})
    return {
        "five_hour": {"utilization": session_pct * 1.0, "resets_at": session_reset},
        "seven_day": {"utilization": weekly_pct * 1.0, "resets_at": weekly_reset},
        "seven_day_opus": None,
        "limits": limits,
    }

def mock_presets():
    now = time.now()
    session_reset = iso(now + time.parse_duration("3h14m"))
    weekly_reset = iso(now + time.parse_duration("124h"))
    return {
        "happy": mock_usage(62, 31, session_reset, weekly_reset),
        "high": mock_usage(95, 83, session_reset, weekly_reset),
        "zero": mock_usage(0, 0, session_reset, weekly_reset),
        "scoped": mock_usage(62, 31, session_reset, weekly_reset, scoped = 12),
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
        return mock_presets()[mock], False, None

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

TRACK_COLOR = "#222"
LABEL_COLOR = "#888"

def pct_color(pct):
    if pct >= 80:
        return "#F44336"
    if pct >= 50:
        return "#FFC107"
    return "#4CAF50"

# plots a 2px-thick ring, filled clockwise from 12 o'clock up to frac
def ring_pixels(diameter, frac, fill_color):
    c = (diameter - 1) / 2.0
    pixels = {}
    for radius in [c, c - 1]:
        steps = int(radius * 8)
        for i in range(steps):
            f = i / float(steps)
            x = int(c + radius * math.sin(f * 2 * math.pi) + 0.5)
            y = int(c - radius * math.cos(f * 2 * math.pi) + 0.5)
            color = fill_color if f < frac else TRACK_COLOR
            if (x, y) not in pixels:
                pixels[(x, y)] = color
    return [
        render.Padding(pad = (x, y, 0, 0), child = render.Box(width = 1, height = 1, color = color))
        for (x, y), color in pixels.items()
    ]

def gauge(label, pct, diameter, show_label):
    pct = min(max(pct, 0), 100)
    color = pct_color(pct)
    lines = []
    if show_label:
        lines.append(render.Text(label, font = "tom-thumb", color = LABEL_COLOR))
        lines.append(render.Text("%d%%" % pct, font = "tom-thumb", color = color))
    else:
        lines.append(render.Text("%d" % pct, font = "tom-thumb", color = color))
    return render.Stack(
        children = [render.Box(width = diameter, height = diameter)] +
                   ring_pixels(diameter, pct / 100.0, color) + [
            render.Box(
                width = diameter,
                height = diameter,
                child = render.Column(
                    main_align = "center",
                    cross_align = "center",
                    children = lines,
                ),
            ),
        ],
    )

def self_test():
    px = ring_pixels(26, 1.0, "#fff")
    if len(px) < 100:
        fail("ring too sparse: %d px" % len(px))
    if pct_color(49) != "#4CAF50" or pct_color(50) != "#FFC107" or pct_color(80) != "#F44336":
        fail("pct_color thresholds wrong")
    if time.parse_time("2026-07-27T16:59:59.538484+00:00").year != 2026:
        fail("parse_time failed on fractional-second timestamp")

def limit_label(entry):
    kind = entry.get("kind")
    if kind == "session":
        return "5H"
    if kind == "weekly_all":
        return "WK"
    scope = entry.get("scope") or {}
    model = scope.get("model") or {}
    name = model.get("display_name") or "??"
    return name[:2].upper()

def limits_from(usage):
    entries = usage.get("limits")
    if entries:
        return [(limit_label(e), int(e["percent"]), e.get("resets_at")) for e in entries if e.get("percent") != None]
    pairs = [("5H", usage.get("five_hour")), ("WK", usage.get("seven_day"))]
    return [(label, int(l["utilization"]), l.get("resets_at")) for label, l in pairs if l and l.get("utilization") != None]

# light shape check: time.parse_time crashes the applet on malformed input,
# and Starlark has no try/except, so only parse RFC3339-looking strings
def parseable_time(s):
    return len(s) >= 19 and "T" in s and "-" in s

def reset_row(limits):
    tightest = None
    for label, pct, resets_at in limits:
        if resets_at and parseable_time(resets_at) and (tightest == None or pct > tightest[1]):
            tightest = (label, pct, resets_at)
    if tightest == None:
        return None
    d = time.parse_time(tightest[2]) - time.now()
    total_m = int(d.minutes)
    if total_m < 0:
        total_m = 0

    # starlark %d takes no width flags; pad manually
    mins = "%d" % (total_m % 60)
    if len(mins) < 2:
        mins = "0" + mins
    txt = "%s RST %dH%sM" % (tightest[0], total_m // 60, mins)
    return render.Text(txt, font = "tom-thumb", color = LABEL_COLOR)

def message_frame(title, body_text, color):
    return render.Root(
        child = render.Column(
            expanded = True,
            main_align = "center",
            cross_align = "center",
            children = [
                render.Text(title, font = "tom-thumb", color = color),
                render.Text(body_text, font = "tom-thumb", color = LABEL_COLOR),
            ],
        ),
    )

def main(config):
    if config.bool("self_test"):
        self_test()

    usage, stale, err = get_usage(config)
    if err == "setup":
        return message_frame("CLAUDE USAGE", "SETUP: ADD TOKEN", "#4CAF50")
    if err == "expired":
        return message_frame("CLAUDE USAGE", "TOKEN EXPIRED", "#F44336")
    if err:
        return message_frame("CLAUDE USAGE", err.upper(), "#F44336")

    limits = limits_from(usage)[:3]
    if not limits:
        return message_frame("CLAUDE USAGE", "NO LIMITS", "#F44336")
    if len(limits) > 2:
        body = render.Row(
            expanded = True,
            main_align = "space_evenly",
            children = [
                render.Column(
                    cross_align = "center",
                    children = [
                        gauge(label, pct, 20, False),
                        render.Text(label, font = "tom-thumb", color = LABEL_COLOR),
                    ],
                )
                for label, pct, _ in limits
            ],
        )
    else:
        body = render.Row(
            expanded = True,
            main_align = "space_evenly",
            children = [gauge(label, pct, 26, True) for label, pct, _ in limits],
        )
    children = [body]
    if config.bool("show_reset", True):
        row = reset_row(limits)
        if row != None:
            children = [row, body]
    root_child = render.Column(
        expanded = True,
        main_align = "end",
        children = children,
    )
    if stale:
        root_child = render.Stack(children = [
            root_child,
            render.Padding(pad = (63, 0, 0, 0), child = render.Box(width = 1, height = 1, color = "#FFC107")),
        ])
    return render.Root(child = root_child)

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
