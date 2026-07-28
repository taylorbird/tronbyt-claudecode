"""Claude subscription usage limits as radial gauges."""

load("cache.star", "cache")
load("encoding/json.star", "json")
load("http.star", "http")
load("math.star", "math")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

LAST_GOOD_KEY = "claude_usage_last_good"

# used when the device/config provides no $tz
DEFAULT_TZ = "America/Los_Angeles"

# The companion keeps serving its last good numbers (HTTP 200) even while its own
# fetches to Anthropic fail, so an HTTP-level check can't detect staleness. It
# instead reports the last successful fetch time and error under this key, and we
# compare against the wall clock: a warning border past STALE_AFTER, and an error
# frame past DEAD_AFTER, because by then the percentages are fiction.
COMPANION_KEY = "_companion"
STALE_AFTER = 360
DEAD_AFTER = 900

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
        COMPANION_KEY: {"fetched_at": int(time.now().unix), "error": None},
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
#
# Auth lives in the companion (scripts/serve_usage.py), which republishes
# the Anthropic usage JSON verbatim; the app just fetches that URL.
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

    url = config.str("data_url")
    if not url:
        return None, False, "setup"

    res = http.get(url, ttl_seconds = 60)
    if res.status_code == 200:
        cache.set(LAST_GOOD_KEY, res.body(), ttl_seconds = 86400)
        return json.decode(res.body()), False, None
    cached = cache.get(LAST_GOOD_KEY)
    if cached:
        return json.decode(cached), True, None

    # The companion's error responses carry {"error": "..."} — surface that
    # rather than a bare status code, so a dead token doesn't read as "HTTP 503".
    body = json.decode(res.body(), None)
    detail = body.get("error") if type(body) == "dict" else None
    return None, False, err_code(detail or "http %d" % res.status_code)

# condenses a companion/fetch error into a label that fits the 64px screen
def err_code(err):
    if not err:
        return "NO DATA"
    e = err.lower()
    if "429" in e or "rate limit" in e or "backing off" in e:
        return "RATE LIMIT"
    if "invalid_grant" in e or "rejected" in e:
        return "AUTH DEAD"
    if "keychain" in e:
        return "KEYCHAIN"
    if "401" in e or "403" in e:
        return "AUTH FAIL"
    return "FETCH FAIL"

# returns (seconds since the companion's last good fetch or None, error or None)
def companion_status(usage):
    meta = usage.get(COMPANION_KEY) or {}
    fetched_at = meta.get("fetched_at")
    age = None
    if fetched_at != None:
        age = int(time.now().unix) - int(fetched_at)
        if age < 0:  # clock skew between the companion host and the device
            age = 0
    return age, meta.get("error")

def age_text(age):
    if age == None:
        return "?"
    if age >= 24 * 3600:
        return "%dD" % (age // (24 * 3600))
    if age >= 3600:
        return "%dH%dM" % (age // 3600, (age % 3600) // 60)
    return "%dM" % (age // 60)

TRACK_COLOR = "#222"
LABEL_COLOR = "#888"
DAY_COLOR = "#4FC3F7"
STALE_COLOR = "#FFC107"

# red screen border once the session or weekly limit reaches this
ALERT_PCT = 90

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
    if err_code("token refresh rate limited (HTTP 429)") != "RATE LIMIT":
        fail("err_code missed a 429")
    if err_code("HTTP 400: invalid_grant") != "AUTH DEAD":
        fail("err_code missed a dead refresh token")
    if err_code(None) != "NO DATA":
        fail("err_code mishandled a missing error")
    if age_text(90) != "1M" or age_text(3660) != "1H1M" or age_text(90000) != "1D":
        fail("age_text formatting wrong")
    fresh_age, fresh_err = companion_status(mock_usage(1, 1, None, None))
    if fresh_age == None or fresh_age > 5 or fresh_err != None:
        fail("companion_status wrong on fresh data: %s / %s" % (fresh_age, fresh_err))
    if companion_status({"limits": []}) != (None, None):
        fail("companion_status should report unknown age when metadata is absent")

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

def countdown_text(d):
    total_m = int(d.minutes)
    if total_m < 0:
        total_m = 0
    if total_m >= 24 * 60:
        return "%dD" % (total_m // (24 * 60))

    # starlark %d takes no width flags; pad manually
    mins = "%d" % (total_m % 60)
    if len(mins) < 2:
        mins = "0" + mins
    return "%dH%sM" % (total_m // 60, mins)

# one animation frame per limit: local reset clock time plus countdown,
# e.g. "5H 23:29(1H22M)" / "WK MON 17:00(4D)" (>=24h out gets a weekday).
# Emphasis: tom-thumb (the only font fitting the 6px row) has no bold, so
# the label is white against the gray remainder instead.
def reset_frames(limits, tz):
    now = time.now()
    frames = []
    for label, _, resets_at in limits:
        if not resets_at or not parseable_time(resets_at):
            continue
        t = time.parse_time(resets_at).in_location(tz)
        parts = [render.Text(label + " ", font = "tom-thumb", color = "#FFFFFF")]
        if int((t - now).hours) >= 24:
            parts.append(render.Text(t.format("Mon").upper() + " ", font = "tom-thumb", color = DAY_COLOR))
        parts.append(render.Text("%s(%s)" % (t.format("15:04"), countdown_text(t - now)), font = "tom-thumb", color = LABEL_COLOR))
        frames.append(render.Row(children = parts))
    return frames

def reset_row(limits, tz):
    # session + weekly cover the distinct reset times; a scoped weekly limit
    # resets together with the weekly one, so skip it to avoid duplicates
    frames = reset_frames([l for l in limits if l[0] in ("5H", "WK")], tz)
    if not frames:
        return None
    if len(frames) == 1:
        return frames[0]
    return render.Animation(children = frames)

def alert_border(child, color):
    return render.Stack(children = [
        child,
        render.Box(width = 64, height = 1, color = color),
        render.Padding(pad = (0, 31, 0, 0), child = render.Box(width = 64, height = 1, color = color)),
        render.Box(width = 1, height = 32, color = color),
        render.Padding(pad = (63, 0, 0, 0), child = render.Box(width = 1, height = 32, color = color)),
    ])

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
        return message_frame("CLAUDE USAGE", "SET DATA URL", "#4CAF50")
    if err == "expired":
        return message_frame("CLAUDE USAGE", "TOKEN EXPIRED", "#F44336")
    if err:
        return message_frame("CLAUDE USAGE", err.upper(), "#F44336")

    # Past DEAD_AFTER the companion's numbers are stale enough to be misleading,
    # so replace them with the reason rather than showing a frozen reading.
    age, companion_err = companion_status(usage)
    if age != None and age >= DEAD_AFTER:
        return message_frame("STALE %s" % age_text(age), err_code(companion_err), "#F44336")
    if companion_err or (age != None and age >= STALE_AFTER):
        stale = True

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
        row = reset_row(limits, config.get("$tz") or DEFAULT_TZ)
        if row != None:
            children = [render.Box(width = 64, height = 6, child = row), body]
    root_child = render.Column(
        expanded = True,
        main_align = "end",
        children = children,
    )
    alert = False
    for label, pct, _ in limits:
        if label in ("5H", "WK") and pct >= ALERT_PCT:
            alert = True
            break

    # A red limit border outranks the amber stale border — a real 90%+ reading is
    # the more urgent of the two, and only one border fits.
    if alert:
        root_child = alert_border(root_child, "#F44336")
    elif stale:
        root_child = alert_border(root_child, STALE_COLOR)

    # delay is per animation frame: the reset row alternates 5H/WK every 2.5s
    return render.Root(delay = 2500, child = root_child)

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Text(
                id = "data_url",
                name = "Data URL",
                desc = "usage.json URL served by scripts/serve_usage.py",
                icon = "link",
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
