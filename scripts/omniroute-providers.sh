#!/usr/bin/env bash
# =============================================================================
# omniroute-providers.sh — provision the router's providers. (M13, ADR-0021)
# =============================================================================
#
# WHY THIS SCRIPT EXISTS AT ALL
#   Every other service in this repo is configured by a file under version
#   control (ADR-0014). OmniRoute cannot be: it reads no providers.json of any
#   kind — verified by inspecting the image, not assumed — and keeps provider
#   state exclusively in SQLite, entered through its HTTP API or its dashboard.
#   The dashboard is not deployed (it is a separate, ~2x larger image tag).
#
#   So this script IS the config file. It is idempotent and re-runnable, which
#   is the closest this service can get to "declared in Git".
#
# THE DATA MODEL, WHICH IS NOT OBVIOUS
#   A provider is TWO records, not one:
#
#     provider_node  — the template: type, base URL, paths. No credentials.
#     connection     — the instance: a node plus an API key, enabled or not.
#
#   POSTing to /api/providers (connections) with a bare type fails with
#   "Invalid provider" until a node of that type exists. The node comes first.
#
# RUN IT FROM THE REPO ROOT
#   ./scripts/omniroute-providers.sh
#
# It talks to the container over docker exec on the server, so it needs the
# same SSH access deploy.sh uses and no published port.
# =============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/life-server}"
SERVER="${SERVER:-deploy@62.238.4.64}"
PREFIX="${ENV_PREFIX_NAME:-prod-}"

# Reuse deploy.sh's multiplexed connection if it is open; ufw rate-limits port
# 22 at six new connections per 30s and this script would otherwise add several.
SSH_CTL="$HOME/.ssh/ls-deploy-%r@%h:%p"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes
	-o ControlMaster=auto -o ControlPath="$SSH_CTL" -o ControlPersist=120)

[[ -f "$REPO/.env" ]] || { echo "error: .env missing" >&2; exit 1; }

get() { grep -E "^$1=" "$REPO/.env" | head -1 | cut -d= -f2-; }

PW="$(get OMNIROUTE_INITIAL_PASSWORD)"
PROXY_KEY="$(get PROXY_API_KEY)"
CLAW_KEY="$(get OMNIROUTE_API_KEY)"

[[ -n "$PW" ]] || { echo "error: OMNIROUTE_INITIAL_PASSWORD not in .env" >&2; exit 1; }

# The whole conversation with the router happens inside a throwaway container
# sharing prod-omniroute's network namespace: the router publishes no port
# (ADR-0003) and ships neither curl nor wget itself.
#
# Secrets travel as environment variables, never on the command line, so they
# do not land in `ps` output or the server's shell history.
ssh "${SSH_OPTS[@]}" "$SERVER" \
	PREFIX="$PREFIX" PW="$PW" PROXY_KEY="$PROXY_KEY" CLAW_KEY="$CLAW_KEY" \
	'bash -s' <<'REMOTE'
set -euo pipefail
# ssh sets these as shell variables, not exported ones, and `docker run -e VAR`
# reads the ENVIRONMENT. Without this the container gets empty strings and the
# login silently fails — which is exactly how this script produced no output at
# all on its first run.
export PREFIX PW PROXY_KEY CLAW_KEY

# The inner script is written to a file FIRST and fed to the container from
# there. Piping it as a heredoc would make it share stdin with the outer
# heredoc that ssh is already reading, and `docker run` would swallow the rest
# of this script — which is precisely why the first version ran and printed
# nothing at all.
cat > /tmp/omniroute-provision.sh <<'INNER'
set -eu
apk add -q --no-cache curl
B=http://127.0.0.1:20128
J=/tmp/jar

api() { # method path [json-file]
	if [ -n "${3:-}" ]; then
		curl -sS -b "$J" --max-time 30 -X "$1" \
			-H 'Content-Type: application/json' --data-binary "@$3" "$B$2"
	else
		curl -sS -b "$J" --max-time 30 -X "$1" "$B$2"
	fi
}

# ── log in ────────────────────────────────────────────────────────────────
# Any username is accepted; only the password is checked (observed, and worth
# knowing — the password is the only thing guarding this API).
printf '{"email":"admin","password":"%s"}' "$PW" > /tmp/login.json
curl -sS -c "$J" -o /dev/null --max-time 20 -X POST \
	-H 'Content-Type: application/json' --data-binary @/tmp/login.json \
	"$B/api/auth/login"
echo "logged in"

# ── tier 1: the subscription proxy ────────────────────────────────────────
# Idempotent: skip if a node of this name already exists.
if api GET /api/provider-nodes | grep -q '"name":"cliproxy"'; then
	echo "node cliproxy: exists"
else
	cat > /tmp/node.json <<EOF
{"type":"openai-compatible","name":"cliproxy","apiType":"chat","prefix":"cliproxy",
 "baseUrl":"http://${PREFIX}cliproxy:8317/v1",
 "chatPath":"/chat/completions","modelsPath":"/models"}
EOF
	echo "node cliproxy: $(api POST /api/provider-nodes /tmp/node.json | head -c 300)"
fi

NODE_ID=$(api GET /api/provider-nodes \
	| sed 's/},{/}\n{/g' | grep '"name":"cliproxy"' \
	| sed 's/.*"id":"\([^"]*\)".*/\1/' | head -1)
echo "node id: ${NODE_ID:-NONE}"

if [ -n "${NODE_ID:-}" ]; then
	if api GET /api/providers | grep -q '"name":"claude-subscription"'; then
		echo "connection claude-subscription: exists"
	else
		cat > /tmp/conn.json <<EOF
{"provider":"$NODE_ID","name":"claude-subscription","apiKey":"$PROXY_KEY","enabled":true}
EOF
		echo "connection: $(api POST /api/providers /tmp/conn.json | head -c 400)"
	fi
fi

# ── the bearer OpenClaw presents ──────────────────────────────────────────
if api GET /api/keys | grep -q '"name":"openclaw"'; then
	echo "key openclaw: exists"
else
	cat > /tmp/key.json <<EOF
{"name":"openclaw","key":"$CLAW_KEY"}
EOF
	echo "key openclaw: $(api POST /api/keys /tmp/key.json | head -c 300)"
fi

echo "--- state ---"
echo "nodes:       $(api GET /api/provider-nodes | head -c 220)"
echo "connections: $(api GET /api/providers    | head -c 220)"
echo "models:      $(api GET /api/models       | head -c 220)"
INNER

docker run --rm --network "container:${PREFIX}omniroute" \
	-e PW -e PROXY_KEY -e CLAW_KEY -e PREFIX \
	-v /tmp/omniroute-provision.sh:/provision.sh:ro \
	alpine:3.21 sh /provision.sh
rm -f /tmp/omniroute-provision.sh
REMOTE
