# =============================================================================
# Dockerfile — OpenClaw plus the tooling to build and deploy. (M15, ADR-0023)
# =============================================================================
#
# WHY THIS EXISTS
#   The operator asked for an agent that can build services on this host. The
#   socket alone does not do that: upstream's image ships no Docker client, so
#   a mounted /var/run/docker.sock would be an unusable file.
#
#   This adds the client and the handful of tools that turn "can call the
#   daemon" into "can actually build something", on top of the pinned upstream
#   image. Nothing else about the image changes.
#
# WHAT THIS CONTAINER CAN DO ONCE THE SOCKET IS MOUNTED
#   Everything root can do on the host. The Docker API has no notion of
#   partial access — a client that can create containers can create one with /
#   bind-mounted. That is not a flaw being worked around here; it is the
#   documented consequence of the decision recorded in ADR-0023.
# =============================================================================

FROM openclaw/openclaw:2026.7.1-slim

USER root

# docker-ce-cli: the client only, NOT the daemon — the daemon is the host's,
# reached through the mounted socket. compose-plugin because "build an app" in
# this stack means writing a compose file, not running raw `docker run`.
#
# Debian bookworm: verified against the running container's /etc/os-release,
# not assumed. An Alpine assumption here would fail at apt.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		ca-certificates curl gnupg \
	&& install -m 0755 -d /etc/apt/keyrings \
	&& curl -fsSL https://download.docker.com/linux/debian/gpg \
		| gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
	&& chmod a+r /etc/apt/keyrings/docker.gpg \
	&& echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian bookworm stable" \
		> /etc/apt/sources.list.d/docker.list \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends \
		docker-ce-cli docker-compose-plugin \
		jq make \
	&& rm -rf /var/lib/apt/lists/*

# The workspace is a named volume mounted at runtime; creating it here with the
# right owner means the agent can write to it on first start without a chown
# racing the entrypoint.
RUN mkdir -p /workspace && chown node:node /workspace

USER node
