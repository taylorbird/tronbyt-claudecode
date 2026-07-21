# Claude Usage Tronbyt App Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** A Pixlet app that renders Claude subscription usage limits (5-hour session + weekly, from the OAuth usage endpoint) as radial ring gauges on a 64×32 Tronbyt display.

**Architecture:** Single Starlark file (`claude_usage.star`). It fetches `GET https://api.anthropic.com/api/oauth/usage` with a user-supplied OAuth token (http-level 2-minute cache), keeps a 24-hour last-good copy via `cache.star`, and draws rings by plotting 1×1 boxes around a circle with `math.sin/cos`. A `dev_mock` config key (not in the schema, CLI-only) feeds canned responses so every visual state renders without API calls.

**Tech Stack:** Pixlet 0.53.x (tronbyt fork, via Homebrew), Starlark modules `render/http/cache/schema/time/math/encoding/json`.

**Design doc:** `docs/plans/2026-07-21-claude-usage-tronbyt-design.md`

**Testing note:** Pixlet has no unit-test runner. The test cycle for each task is: run `pixlet render` with a config that exercises the new behavior, confirm it fails (or renders wrong) first, implement, re-render, confirm exit code 0 and eyeball the output. Render commands write to `/tmp/claude_usage/` — create it once with `mkdir -p /tmp/claude_usage`. View any output with `open <file>`.

---

### Task 1: Toolchain + scaffolding

**Files:**
- Create: `manifest.yaml`
- Create: `claude_usage.star` (walking skeleton)
- Create: `.gitignore`

**Step 1: Install pixlet**

Run: `brew install pixlet`
Verify: `pixlet version` → prints `v0.53.1` (or newer).

**Step 2: Write the walking skeleton**

`claude_usage.star`:

```starlark
"""Claude subscription usage limits as radial gauges."""

load("render.star", "render")
load("schema.star", "schema")

def main(config):
    return render.Root(
        child = render.Text("CLAUDE"),
    )

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
```

`manifest.yaml`:

```yaml
id: claude-usage
name: Claude Usage
summary: Claude plan usage limits
desc: Displays your Claude subscription 5-hour and weekly usage limits as radial ring gauges, the same numbers as Claude Code's /usage command.
author: Taylor Bird
```

`.gitignore`:

```
*.webp
*.gif
```

**Step 3: Verify it renders**

Run: `mkdir -p /tmp/claude_usage`
Run: `pixlet render claude_usage.star -o /tmp/claude_usage/skeleton.webp`
Expected: exit 0. `open /tmp/claude_usage/skeleton.webp` shows "CLAUDE".

**Step 4: Commit**

```bash
git add manifest.yaml claude_usage.star .gitignore
git commit -m "feat: scaffold claude_usage pixlet app"
```

---

### Task 2: Verify the usage endpoint empirically

The design's one unverified assumption. Do this BEFORE building the fetch layer so the mock data matches reality.

**Files:**
- Create: `docs/api-notes.md`

**Step 1: Test with the current Claude Code access token**

macOS stores Claude Code credentials in the Keychain. Extract the access token and call the endpoint:

```bash
TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w | python3 -c "import sys, json; print(json.load(sys.stdin)['claudeAiOauth']['accessToken'])")
curl -sS -w '\nHTTP %{http_code}\n' \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "User-Agent: claude-code/2.1.9" \
  https://api.anthropic.com/api/oauth/usage
```

Expected: `HTTP 200` and a JSON body. Record the EXACT body (redact nothing but the token) in `docs/api-notes.md` — field names, whether `utilization` is int or float, `resets_at` format, and any extra limit objects (`seven_day_opus` etc.). All later mock data must copy this shape verbatim.

If this 401s: the keychain token may be stale; ask the user to run any Claude Code command to refresh it, then retry.

**Step 2: Test the long-lived setup token**

Ask the user to run `claude setup-token` in their terminal (it's an interactive browser flow) and paste the resulting `sk-ant-oat01-…` token. Re-run the curl from Step 1 with that token.

- **HTTP 200** → the preferred auth path works. Note it in `docs/api-notes.md`. `scripts/get_token.py` is NOT needed; skip nothing else.
- **HTTP 401/403** → record that. Add a follow-up task (after Task 8) to build `scripts/get_token.py`, a PKCE OAuth helper that creates a separate grant, and extend the app to refresh tokens in Starlark per the design doc. Flag this to the user immediately — it changes setup UX.

**Step 3: Commit**

```bash
git add docs/api-notes.md
git commit -m "docs: record verified usage endpoint response shape"
```

---

### Task 3: Fetch layer with dev_mock presets

**Files:**
- Modify: `claude_usage.star`

**Step 1: Write the failing render (test first)**

Run: `pixlet render claude_usage.star dev_mock=happy -o /tmp/claude_usage/fetch.webp`
Expected now: renders "CLAUDE" (mock ignored) — i.e. the behavior under test doesn't exist yet.

**Step 2: Implement fetch + mocks**

Add to `claude_usage.star` (adjust MOCKS to the exact shape recorded in `docs/api-notes.md` — the snippet below assumes the community-documented shape):

```starlark
load("http.star", "http")
load("cache.star", "cache")
load("encoding/json.star", "json")

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
USER_AGENT = "claude-code/2.1.9"
LAST_GOOD_KEY = "claude_usage_last_good"

MOCKS = {
    "happy": {"five_hour": {"utilization": 62, "resets_at": "2026-07-21T20:00:00Z"}, "seven_day": {"utilization": 31, "resets_at": "2026-07-24T09:00:00Z"}},
    "high": {"five_hour": {"utilization": 95, "resets_at": "2026-07-21T20:00:00Z"}, "seven_day": {"utilization": 83, "resets_at": "2026-07-24T09:00:00Z"}},
    "zero": {"five_hour": {"utilization": 0, "resets_at": "2026-07-21T20:00:00Z"}, "seven_day": {"utilization": 0, "resets_at": "2026-07-24T09:00:00Z"}},
    "opus": {"five_hour": {"utilization": 62, "resets_at": "2026-07-21T20:00:00Z"}, "seven_day": {"utilization": 31, "resets_at": "2026-07-24T09:00:00Z"}, "seven_day_opus": {"utilization": 12, "resets_at": "2026-07-24T09:00:00Z"}},
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
```

Temporarily wire `main` to prove the plumbing (replaced in Task 5):

```starlark
def main(config):
    usage, stale, err = get_usage(config)
    if err:
        return render.Root(child = render.Text(err))
    return render.Root(child = render.Text("5H %d WK %d" % (
        int(usage["five_hour"]["utilization"]),
        int(usage["seven_day"]["utilization"]),
    )))
```

**Step 3: Verify**

Run: `pixlet render claude_usage.star dev_mock=happy -o /tmp/claude_usage/fetch.webp`
Expected: exit 0, image shows "5H 62 WK 31".
Run: `pixlet render claude_usage.star dev_mock=expired -o /tmp/claude_usage/fetch-expired.webp`
Expected: shows "expired".
Run: `pixlet render claude_usage.star -o /tmp/claude_usage/fetch-setup.webp`
Expected: shows "setup".

**Step 4: Commit**

```bash
git add claude_usage.star
git commit -m "feat: usage fetch layer with dev_mock presets and stale cache"
```

---

### Task 4: Ring-drawing primitives

**Files:**
- Modify: `claude_usage.star`

**Step 1: Failing render**

Run: `pixlet render claude_usage.star dev_mock=happy self_test=1 -o /tmp/claude_usage/selftest.webp`
Expected now: renders normally (self_test not implemented) — no assertion coverage yet.

**Step 2: Implement**

```starlark
load("math.star", "math")

TRACK_COLOR = "#222"

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
    color = pct_color(pct)
    lines = []
    if show_label:
        lines.append(render.Text(label, font = "tom-thumb", color = "#888"))
    lines.append(render.Text("%d%%" % pct, font = "tom-thumb", color = color))
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
    for p in ring_pixels(26, 0.5, "#fff"):
        pass
    if pct_color(49) != "#4CAF50" or pct_color(50) != "#FFC107" or pct_color(80) != "#F44336":
        fail("pct_color thresholds wrong")
```

In `main`, before anything else:

```starlark
    if config.bool("self_test"):
        self_test()
```

**Step 3: Verify**

Run: `pixlet render claude_usage.star dev_mock=happy self_test=1 -o /tmp/claude_usage/selftest.webp`
Expected: exit 0 (assertions pass). Break a threshold on purpose, re-run, confirm it fails with the `fail()` message, revert.

Temporarily render one gauge to eyeball geometry:

```starlark
    return render.Root(child = gauge("5H", 62, 26, True))
```

Run: `pixlet render claude_usage.star dev_mock=happy -o /tmp/claude_usage/ring.gif --gif --magnify 8`
Eyeball `open /tmp/claude_usage/ring.gif`: closed circle outline, fill starts at 12 o'clock going clockwise ~62% around, label over percentage centered, no stray pixels outside the ring box.

**Step 4: Commit**

```bash
git add claude_usage.star
git commit -m "feat: radial ring gauge primitives with self-test asserts"
```

---

### Task 5: Two-ring layout

**Files:**
- Modify: `claude_usage.star`

Geometry budget (32px tall): reset row 6px + 26px rings = 32. With `show_reset=false`, rings get 3px top margin instead. Each ring centers in a 32px-wide half.

**Step 1: Failing render**

Run: `pixlet render claude_usage.star dev_mock=happy show_reset=false -o /tmp/claude_usage/two.webp`
Expected now: still the single-ring/temporary output.

**Step 2: Implement**

Replace the temporary `main` body's success path:

```starlark
def limits_from(usage):
    limits = [("5H", usage["five_hour"]), ("WK", usage["seven_day"])]
    if "seven_day_opus" in usage:
        limits.append(("OP", usage["seven_day_opus"]))
    return [(label, int(l["utilization"]), l.get("resets_at")) for label, l in limits]

def main(config):
    if config.bool("self_test"):
        self_test()
    usage, stale, err = get_usage(config)
    if err:
        return render.Root(child = render.Text(err))  # replaced in Task 8
    limits = limits_from(usage)
    diameter = 26 if len(limits) == 2 else 20
    rings = render.Row(
        expanded = True,
        main_align = "space_evenly",
        children = [gauge(label, pct, diameter, True) for label, pct, _ in limits],
    )
    return render.Root(
        child = render.Column(
            expanded = True,
            main_align = "end",
            children = [rings],
        ),
    )
```

(`main_align = "end"` bottom-aligns the rings so Task 7's reset row drops into the free top 6px; with two 26px rings there are 6px spare, with three 20px rings 12px spare — Task 6 uses the extra for labels.)

**Step 3: Verify**

Run: `pixlet render claude_usage.star dev_mock=happy -o /tmp/claude_usage/two.gif --gif --magnify 8`
Run: `pixlet render claude_usage.star dev_mock=high -o /tmp/claude_usage/two-high.gif --gif --magnify 8`
Run: `pixlet render claude_usage.star dev_mock=zero -o /tmp/claude_usage/two-zero.gif --gif --magnify 8`
Eyeball: two rings side by side; happy = green 62% + green 31%; high = red 95% + red 83%; zero = full gray tracks with "0%". Nothing clipped at the 32px bottom edge.

**Step 4: Commit**

```bash
git add claude_usage.star
git commit -m "feat: two-ring dashboard layout"
```

---

### Task 6: Three-ring (Opus) layout

**Files:**
- Modify: `claude_usage.star`

At 20px diameter the interior is too tight for two text lines, so 3-ring mode puts the percentage alone inside (no `%` if it saves overflow — `"%d" % pct`) and the label in a 6px row *below* the rings: 6 reset + 20 rings + 6 labels = 32.

**Step 1: Failing render**

Run: `pixlet render claude_usage.star dev_mock=opus -o /tmp/claude_usage/opus.gif --gif --magnify 8`
Expected now: three rings but cramped/overflowing text — the defect this task fixes.

**Step 2: Implement**

In 3-ring mode call `gauge(label, pct, 20, False)` (percentage only, and change `gauge` to drop the `%` sign when `diameter < 24`), and wrap rings + a label row:

```starlark
    if len(limits) > 2:
        body = render.Column(children = [
            render.Row(expanded = True, main_align = "space_evenly",
                       children = [gauge(l, p, 20, False) for l, p, _ in limits]),
            render.Row(expanded = True, main_align = "space_evenly",
                       children = [render.Text(l, font = "tom-thumb", color = "#888") for l, _, _ in limits]),
        ])
    else:
        body = rings
```

**Step 3: Verify**

Re-run the Step 1 command. Eyeball: three rings `5H / WK / OP`, labels beneath, percentages legible, nothing clipped. Re-run `dev_mock=happy` to confirm the 2-ring layout is unchanged.

**Step 4: Commit**

```bash
git add claude_usage.star
git commit -m "feat: three-ring layout when an Opus limit is reported"
```

---

### Task 7: Reset countdown row

**Files:**
- Modify: `claude_usage.star`

**Step 1: Failing render**

Run: `pixlet render claude_usage.star dev_mock=happy -o /tmp/claude_usage/reset.gif --gif --magnify 8`
Expected now: no top row.

**Step 2: Implement**

```starlark
load("time.star", "time")

def reset_row(limits):
    tightest = None
    for label, pct, resets_at in limits:
        if resets_at and (tightest == None or pct > tightest[1]):
            tightest = (label, pct, resets_at)
    if tightest == None:
        return None
    d = time.parse_time(tightest[2]) - time.now()
    total_m = int(d.minutes)
    if total_m < 0:
        total_m = 0
    txt = "%s RST %dH%02dM" % (tightest[0], total_m // 60, total_m % 60)
    return render.Text(txt, font = "tom-thumb", color = "#888")
```

In `main`, when `config.bool("show_reset", True)`, prepend `reset_row(limits)` (skip if `None`) to the top of the column.

**Step 2a: Mock-time caveat**

`time.now()` vs. the mock's fixed `resets_at` gives a nonsense (likely negative→0) countdown as dates drift. Regenerate mock `resets_at` values relative to now instead: in `MOCKS`, replace the literals using `time.now() + time.parse_duration("3h")` etc. computed inside `get_usage` for mock mode (Starlark forbids most module-level side effects at load; do it in the function).

**Step 3: Verify**

Run: `pixlet render claude_usage.star dev_mock=happy -o /tmp/claude_usage/reset.gif --gif --magnify 8`
Eyeball: top row like `5H RST 3H00M`, rings still fully visible below (no clipping).
Run: `pixlet render claude_usage.star dev_mock=happy show_reset=false -o /tmp/claude_usage/noreset.gif --gif --magnify 8`
Eyeball: no top row, rings bottom-anchored.
Run: `pixlet render claude_usage.star dev_mock=opus -o /tmp/claude_usage/opus-reset.gif --gif --magnify 8`
Eyeball: 6+20+6 stack fits exactly.

**Step 4: Commit**

```bash
git add claude_usage.star
git commit -m "feat: reset countdown row for the tightest limit"
```

---

### Task 8: Real error frames + stale indicator

**Files:**
- Modify: `claude_usage.star`

**Step 1: Failing render**

Run: `pixlet render claude_usage.star dev_mock=expired -o /tmp/claude_usage/expired.gif --gif --magnify 8`
Expected now: bare text "expired" (placeholder).

**Step 2: Implement**

```starlark
def message_frame(title, body_text, color):
    return render.Root(
        child = render.Column(
            expanded = True,
            main_align = "center",
            cross_align = "center",
            children = [
                render.Text(title, font = "tom-thumb", color = color),
                render.Text(body_text, font = "tom-thumb", color = "#888"),
            ],
        ),
    )
```

Map errors in `main`:
- `"setup"` → `message_frame("CLAUDE USAGE", "SETUP: ADD TOKEN", "#4CAF50")`
- `"expired"` → `message_frame("CLAUDE USAGE", "TOKEN EXPIRED", "#F44336")`
- anything else → `message_frame("CLAUDE USAGE", err.upper(), "#F44336")`

Stale indicator: when `stale` is true, overlay a single amber pixel top-right — add to the outermost Stack:

```starlark
render.Padding(pad = (63, 0, 0, 0), child = render.Box(width = 1, height = 1, color = "#FFC107"))
```

(Wrap the final body in a `render.Stack` only when `stale`.)

**Step 3: Verify**

Run: `pixlet render claude_usage.star dev_mock=expired -o /tmp/claude_usage/expired.gif --gif --magnify 8` → red TOKEN EXPIRED frame.
Run: `pixlet render claude_usage.star -o /tmp/claude_usage/setup.gif --gif --magnify 8` → SETUP frame.
Run: `pixlet render claude_usage.star dev_mock=outage -o /tmp/claude_usage/outage.gif --gif --magnify 8` → "NO DATA"-style error frame (cache is empty under `pixlet render`, so the stale path degrades to the error frame; the stale-dot path itself gets verified in Task 9 against the live server if reachable, otherwise by temporarily seeding the cache in mock mode, eyeballing, and reverting).

**Step 4: Commit**

```bash
git add claude_usage.star
git commit -m "feat: setup/expired/outage frames and stale-data indicator"
```

---

### Task 9: Live end-to-end render

**Step 1:** Using the token that passed in Task 2 (prefer the `sk-ant-oat01-…` one):

Run: `pixlet render claude_usage.star token=<TOKEN> -o /tmp/claude_usage/live.gif --gif --magnify 8`
Expected: exit 0; rings show your real current percentages (sanity-check against `/usage` in Claude Code). If the response contains limit objects the mocks didn't (e.g. an extra window), fix `limits_from` accordingly, update MOCKS, re-render.

**Step 2:** Run `pixlet serve claude_usage.star` and open http://localhost:8080 — confirm the schema page shows the token + toggle fields and the app renders with a pasted token.

**Step 3: Commit any fixes**

```bash
git add claude_usage.star
git commit -m "fix: adjust to live usage endpoint response"
```

---

### Task 10: README

**Files:**
- Create: `README.md`

Contents: what the app shows (screenshot from `/tmp/claude_usage/two.gif`, copied into `docs/images/`), how to get a token (`claude setup-token`, or the fallback helper if Task 2 forced that path), how to install on a Tronbyt server (upload `claude_usage.star` as a custom app in the Tronbyt web UI, paste token in config), and the dev loop (`pixlet render … dev_mock=happy`). Keep it under a screenful.

**Commit:**

```bash
git add README.md docs/images/
git commit -m "docs: README with setup and dev instructions"
```
