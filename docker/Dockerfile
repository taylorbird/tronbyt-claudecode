# Single image for both services (companion + pusher). It bundles Python (for
# the companion) and the pixlet binary (for rendering), so the only thing the
# host needs is Docker itself.
FROM python:3.12-slim

# pixlet release to install. Override with --build-arg PIXLET_VERSION=x.y.z.
ARG PIXLET_VERSION=0.34.0
# Set automatically by BuildKit/buildx (arm64 on a Raspberry Pi, amd64 on a PC).
ARG TARGETARCH=arm64

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install pixlet. `pixlet version` and a render smoke test run at build time so
# a wrong URL or a missing runtime library fails the build loudly rather than
# at 3am on the Pi.
RUN set -eux; \
    url="https://github.com/tidbyt/pixlet/releases/download/v${PIXLET_VERSION}/pixlet_${PIXLET_VERSION}_linux_${TARGETARCH}.tar.gz"; \
    curl -fsSL "$url" -o /tmp/pixlet.tar.gz; \
    tar -xzf /tmp/pixlet.tar.gz -C /usr/local/bin pixlet; \
    rm /tmp/pixlet.tar.gz; \
    pixlet version

WORKDIR /app
COPY claude_usage.star ./claude_usage.star
COPY scripts/ ./scripts/
RUN chmod +x scripts/render_push.sh \
    && python3 -m py_compile scripts/serve_usage.py \
    && pixlet render /app/claude_usage.star dev_mock=happy self_test=true -o /tmp/smoke.webp \
    && rm /tmp/smoke.webp

# pixlet lives on PATH here; render_push.sh honours PIXLET_BIN.
ENV PIXLET_BIN=/usr/local/bin/pixlet

# All-in-one default: one process that refreshes the token, serves usage on
# localhost, and renders+pushes frames. /config is the writable location for the
# (rotating) credentials file; seed it via CLAUDE_CREDENTIALS_JSON or a mount.
# Needs TRONBYT_URL / DEVICE_ID / API_KEY in the environment.
CMD ["python3", "scripts/serve_usage.py", "--creds-file", "/config/credentials.json", \
     "--push", "--bind", "127.0.0.1", "--port", "8377", "--interval", "120"]
