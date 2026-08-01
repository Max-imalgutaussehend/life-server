# =============================================================================
# Dockerfile — Hermes, the CEO agent runtime. (M11, ADR-0020)
# =============================================================================
#
# WHY THIS IS BUILT AND NOT PULLED
#   Upstream ships Hermes as a pip package (`hermes-agent`) with no official
#   image. Unlike Paperclip — a pnpm monorepo that will not build safely in the
#   memory this host has free — a pip install is small enough to build here.
#
# WHY NOT PAPERCLIP'S Dockerfile.hermes
#   That one is a stub. By its own comment it boots and then fails with "hermes
#   not on PATH", because hermes_local has no upstream package wired in. This
#   image serves the GATEWAY adapter instead, which upstream supports.
# =============================================================================

# 3.13 is not arbitrary: hermes-agent declares requires_python <3.14,>=3.11, so
# 3.14 would fail to install and 3.10 would not resolve.
#
# Alpine is avoided deliberately: hermes-agent pulls dependencies with C
# extensions, and musl wheels are not universally published — a build that
# silently falls back to compiling from source is a slow build that breaks on a
# dependency bump.
FROM python:3.13-slim-trixie

# Pinned. An unpinned agent runtime would change underneath the operator on
# every rebuild, which is exactly what ADR-0011 forbids for images and applies
# no less to what goes inside them.
ARG HERMES_VERSION=0.19.0

# tini as PID 1: the gateway spawns a child process per run, and without an
# init to reap them the container accumulates zombies until it cannot fork.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends tini curl \
	&& rm -rf /var/lib/apt/lists/* \
	&& pip install --no-cache-dir "hermes-agent==${HERMES_VERSION}"

# Non-root. This container executes model-chosen code, so the M9 sandbox rule
# applies in full: uid 65534 owns nothing worth taking, and
# verify-agent-sandbox.sh asserts the workspace is not root.
RUN mkdir -p /data && chown 65534:65534 /data
USER 65534:65534
WORKDIR /data

ENV HOME=/data \
	API_SERVER_ENABLED=true

EXPOSE 8642

ENTRYPOINT ["/usr/bin/tini", "--"]
# --accept-hooks is required for the gateway to serve runs; --replace makes a
# restart take over a stale socket rather than refusing to start.
CMD ["hermes", "gateway", "run", "--replace", "--accept-hooks"]
