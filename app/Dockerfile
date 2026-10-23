# syntax=docker/dockerfile:1
FROM python:3.13-slim

# - no .pyc files in the image, unbuffered stdout/stderr so logs reach
#   `docker logs` (and later CloudWatch) immediately
# - uvicorn reads UVICORN_* variables as CLI options, which keeps CMD in exec
#   form while letting the port be overridden with `-e UVICORN_PORT=...`
# - X-Forwarded-For/-Proto are honoured only from UVICORN_FORWARDED_ALLOW_IPS
#   (comma-separated IPs or CIDRs). The default trusts loopback only, so a
#   directly exposed container ignores spoofed headers; on AWS set it to the
#   VPC CIDR so the ALB is trusted (see README.md, "Trusted proxies")
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    UVICORN_HOST=0.0.0.0 \
    UVICORN_PORT=8080 \
    UVICORN_FORWARDED_ALLOW_IPS=127.0.0.1,::1

WORKDIR /srv/app

RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

# Dependencies first: this layer is reused until requirements.txt changes.
COPY requirements.txt .
RUN pip install --requirement requirements.txt

COPY --chown=root:root . .

USER app

EXPOSE 8080

# Docker-level check for local runs; on AWS the ALB target group health check
# against /health is what decides instance health.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import os, urllib.request; urllib.request.urlopen(f\"http://127.0.0.1:{os.environ.get('UVICORN_PORT', '8080')}/health\", timeout=2)"]

# Exec form: uvicorn runs as PID 1 and receives SIGTERM directly from
# `docker stop`, then finishes in-flight requests before exiting.
CMD ["uvicorn", "main:app"]
