# =============================================================================
# agent-runner — Claude Code sessions, on the server. (M10, ADR-0019)
# =============================================================================
#
# THIS IS THE CONTAINER THE M9 SANDBOX WAS BUILT FOR
#   It executes code chosen by a language model. `verify-agent-sandbox.sh`
#   asserts what it cannot reach: Postgres, Redis, n8n, Caddy, ntfy, Kuma, the
#   Docker socket, .env, the age key. That script is a PRECONDITION for
#   deploying this, not a nice-to-have — it is the only thing standing between
#   a prompt-injected session and the rest of the host.
#
# WHY NODE
#   Claude Code is distributed as an npm package. Nothing else here needs Node,
#   which is exactly why it lives in its own image rather than being bolted onto
#   something existing.
#
# WHY NOT scratch, LIKE paperclip
#   An agent's job is running commands. Stripping the shell would defeat the
#   purpose. The isolation therefore comes from the network boundary and the
#   unprivileged user, not from an empty filesystem.
# =============================================================================

FROM node:22.12-alpine

# git: agents work on repositories.
# ripgrep: Claude Code uses it for search and is markedly slower without it.
# ca-certificates: needed to reach api.anthropic.com.
# bash/curl/jq: the ordinary toolkit a worker ticket expects to find.
# tini: see ENTRYPOINT.
RUN apk add --no-cache \
	bash \
	ca-certificates \
	curl \
	git \
	jq \
	ripgrep \
	tini

# Pinned like every other image (ADR-0011). An agent runtime that silently
# changes under you is the last thing you want when a session starts behaving
# differently.
RUN npm install -g @anthropic-ai/claude-code@2.1.220 \
	&& npm cache clean --force

# The node image ships an unprivileged `node` user (uid 1000). Nothing here runs
# as root, so a session that escapes its working directory still cannot write to
# the system.
RUN mkdir -p /workspaces /home/node/.claude \
	&& chown -R node:node /workspaces /home/node

COPY --chown=node:node run-agent.sh /usr/local/bin/run-agent
RUN chmod +x /usr/local/bin/run-agent

USER node
WORKDIR /workspaces

ENV HOME=/home/node \
	NODE_ENV=production

# tini reaps zombies. Claude Code spawns subprocesses, and without an init
# process a long-running loop accumulates defunct children until the pid table
# is exhausted — a failure that presents as the agent "just stopping".
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["/usr/local/bin/run-agent"]
