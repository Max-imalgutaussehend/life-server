#!/usr/bin/env bash
# =============================================================================
# deploy.sh — sync this repo to the server and bring the stack up.
# =============================================================================
#
# WHY RSYNC AND NOT `git pull` ON THE SERVER
#   During M2-M6 the repo has no remote yet. rsync keeps the server in step
#   with your working copy without requiring GitHub. From M7 this is replaced
#   by a pull-based flow (ADR-0007), which is why the mechanism lives in one
#   script rather than being typed by hand.
#
# WHAT IS SYNCED
#   Everything Git tracks, plus .env — which is deliberately NOT in Git
#   (ADR-0006) but IS required to run. .git/ itself is excluded; the server
#   does not need history.
#
# SAFETY
#   --delete removes files on the server that no longer exist locally, so the
#   server cannot accumulate orphaned config. It is scoped to /opt/life-server,
#   never the whole filesystem.
#
# USAGE
#   make deploy-stack          # sync + up
#   ./scripts/deploy.sh --sync-only
# =============================================================================

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/life-server}"
SERVER="${SERVER:?set SERVER=deploy@<host-ip>}"
REMOTE_DIR="/opt/life-server"
SYNC_ONLY=false

[[ "${1:-}" == "--sync-only" ]] && SYNC_ONLY=true

[[ -f "$REPO/.env" ]] || { echo "error: .env missing. Run: make setup" >&2; exit 1; }

# ── One TCP connection, reused ──────────────────────────────────────────────
# UFW rate-limits port 22 at SIX new connections per 30 seconds (`ufw limit`,
# ADR-0013). This script opens rsync plus four ssh calls, which lands exactly
# on that ceiling — so a routine deploy would intermittently lock the operator
# out of their own server, with `Connection refused` that looks like a dead
# sshd. Diagnosed 2026-08-24 from /proc/net/xt_recent, after fail2ban had been
# wrongly blamed twice (its ignoreip was working fine).
#
# ControlMaster multiplexes every call below over ONE connection, so a deploy
# costs a single slot. Do not "fix" a future rate-limit problem by loosening
# the UFW rule: that rule is absorbing real attacks continuously.
# NOT under $TMPDIR: on macOS that path is ~50 characters before the socket
# name is appended, and a Unix domain socket is capped at 104. The failure is
# "path too long for Unix domain socket", which reads like an ssh bug.
SSH_CTL="$HOME/.ssh/ls-deploy-%r@%h:%p"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes
	-o ControlMaster=auto -o ControlPath="$SSH_CTL" -o ControlPersist=120)

cleanup_ssh() { ssh -O exit -o ControlPath="$SSH_CTL" "$SERVER" 2>/dev/null || true; }
trap cleanup_ssh EXIT

echo "==> syncing $REPO -> $SERVER:$REMOTE_DIR"
rsync -az --delete \
	-e "ssh ${SSH_OPTS[*]}" \
	--exclude '.git/' \
	--exclude '__pycache__/' \
	--exclude '.DS_Store' \
	"$REPO/" "$SERVER:$REMOTE_DIR/"

# .env carries secrets and must not be readable by other users on the host.
ssh "${SSH_OPTS[@]}" "$SERVER" "chmod 600 $REMOTE_DIR/.env"

if $SYNC_ONLY; then
	echo "==> sync complete (--sync-only)"
	exit 0
fi

echo "==> starting stack"
# --env-file twice: .env holds secrets, services.env holds generated hostnames
# and ports (ADR-0014). Compose merges them; later files win.
#
# net-agent is created explicitly because Compose only creates networks that a
# service actually joins, and M9 agent workspaces are started per session by
# `docker run`, not declared as services here. Without this the network exists
# only if someone remembered to create it by hand — and `verify-agent-sandbox`
# would fail for a reason that has nothing to do with the boundary it tests.
ssh "${SSH_OPTS[@]}" "$SERVER" "
	set -euo pipefail
	cd $REMOTE_DIR
	AGENT_NET=\"\$(grep -E '^ENV_PREFIX_NAME=' .env 2>/dev/null | cut -d= -f2-)\"
	AGENT_NET=\"\${AGENT_NET:-prod-}net-agent\"
	docker network inspect \"\$AGENT_NET\" >/dev/null 2>&1 \
		|| docker network create \"\$AGENT_NET\" >/dev/null
	docker compose \
		--env-file .env \
		--env-file compose/generated/services.env \
		-f compose/docker-compose.prod.yml \
		up -d --remove-orphans
"

# Caddy's routes come from a BIND-MOUNTED generated file. Changing that file on
# disk does not change the container's definition, so `compose up -d` leaves the
# old routes loaded and a newly registered service silently returns the
# catch-all 404. Found exactly that way when n8n was added in M6.
#
# `caddy reload` is not an option: the Caddyfile sets `admin off`, so there is no
# admin API to push config to — deliberately. Restarting the container is the
# supported path and costs a sub-second blip on a proxy that holds no state.
#
# Only restarts when the loaded config actually differs, so a routine deploy
# does not needlessly bounce ingress.
CADDY_CONTAINER="$(grep -E '^ENV_PREFIX_NAME=' "$REPO/.env" 2>/dev/null | cut -d= -f2- || true)"
CADDY_CONTAINER="${CADDY_CONTAINER:-prod-}caddy"

echo "==> checking Caddy's loaded routes"
ssh "${SSH_OPTS[@]}" "$SERVER" "
	set -euo pipefail
	cd $REMOTE_DIR
	on_disk=\$(sha256sum compose/generated/caddy/Caddyfile | cut -d' ' -f1)
	loaded=\$(docker exec $CADDY_CONTAINER sha256sum /etc/caddy/Caddyfile 2>/dev/null | cut -d' ' -f1 || echo none)
	if [ \"\$on_disk\" != \"\$loaded\" ]; then
		echo '    generated Caddyfile changed — restarting Caddy'
		docker restart $CADDY_CONTAINER >/dev/null
		sleep 3
	else
		echo '    routes current'
	fi
"

echo "==> container status"
ssh "${SSH_OPTS[@]}" "$SERVER" \
	"docker ps --format 'table {{.Names}}\t{{.Status}}'"
