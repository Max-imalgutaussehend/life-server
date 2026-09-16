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
#
# A COMBO THIS SCRIPT DOES NOT MANAGE, FOUND LIVE ON THE SERVER (2026-09-13)
#   A combo named "free-first" exists in the router's SQLite state, created
#   directly via the API/dashboard rather than through this script — its
#   description even cited "ADR-0030", which does not exist in this repo.
#   OpenClaw's agent (agents.defaults.model.primary) was pointed at
#   `omniroute/free-first`, overriding the `subscription` combo this repo's
#   compose file sets everywhere else.
#
#   ADR-0026 already measured why a free-provider pool cannot serve agents:
#   463 stream failures/hour against 6 from the subscription, plus a run that
#   hung 62 minutes when a free provider accepted a request and went silent.
#   Consistent with that, by 2026-09-13 every one of free-first's 8 providers
#   was dead: nvidia/cerebras/openrouter/gemini had models retired by their
#   provider (404/410 — permanent), sambanova had no credentials configured,
#   and cohere/zai/mistral were quota/balance/rate-limit exhausted (429).
#
#   Fixed in place (not by this script, for the same reason state can't be
#   read back into it below): pruned free-first down to cohere/zai/mistral —
#   the three that can recover without a config change — via
#   PUT /api/combos/{id}. nvidia/cerebras/openrouter/gemini/sambanova were
#   removed since they cannot ever succeed again as configured.
#
#   This script still does not manage free-first or touch OpenClaw's model
#   selection — both remain dashboard/API-set state, invisible to `git diff`.
#   If free-first is to stay, it belongs here, provisioned like the two combos
#   below. Until then, treat any drift between what's live and what this file
#   describes as expected, not a bug in this script.
#
#   TOOL-CALLING ON THE REMAINING THREE, MEASURED DIRECTLY (2026-09-13)
#   The operator disputed ADR-0026's claim that the free pool can't do tool
#   calling. Tested by sending a real tools-array chat request straight to
#   omniroute for each of cohere/command-a-03-2025, zai/glm-5-turbo, and
#   mistral/mistral-small-latest. Result: all three returned 429 (cohere trial
#   quota, zai zero balance, mistral rate-limited) — none reached the model,
#   so **this did not confirm or refute tool-calling support**. The 429s were
#   not caused by the test; the same three accounts were already saturated by
#   free-first's live OpenClaw traffic at the time. Re-run this test —
#   scripts stashed nowhere permanent, see git history around this comment
#   for the curl shape — once one of the three has quota again, before
#   concluding either way.
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
# Tier 2. Empty is a supported state, not an error: the node and connection are
# still created, but the connection is created DISABLED, so the router keeps
# using tier 1 alone. That is ADR-0021's "inert until keyed" — expressed as a
# provisioning outcome rather than a hand-edited JSON flag.
ANTHROPIC_KEY="$(get ANTHROPIC_API_KEY)"

[[ -n "$PW" ]] || { echo "error: OMNIROUTE_INITIAL_PASSWORD not in .env" >&2; exit 1; }

# The whole conversation with the router happens inside a throwaway container
# sharing prod-omniroute's network namespace: the router publishes no port
# (ADR-0003) and ships neither curl nor wget itself.
#
# Secrets travel as environment variables, never on the command line, so they
# do not land in `ps` output or the server's shell history.
ssh "${SSH_OPTS[@]}" "$SERVER" \
	PREFIX="$PREFIX" PW="$PW" PROXY_KEY="$PROXY_KEY" CLAW_KEY="$CLAW_KEY" \
	ANTHROPIC_KEY="$ANTHROPIC_KEY" \
	'bash -s' <<'REMOTE'
set -euo pipefail
# ssh sets these as shell variables, not exported ones, and `docker run -e VAR`
# reads the ENVIRONMENT. Without this the container gets empty strings and the
# login silently fails — which is exactly how this script produced no output at
# all on its first run.
export PREFIX PW PROXY_KEY CLAW_KEY ANTHROPIC_KEY

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

# ── tier 2: Anthropic direct (ADR-0021) ───────────────────────────────────
# WHY THIS EXISTS: with tier 1 alone, every agent turn is charged to the Pro
# subscription. That is the whole complaint — the router cannot spread load it
# has nowhere to spread it TO. A second tier is the only thing that changes
# where the tokens are billed.
#
# It is NOT the free-provider pool. That was tried and is incapable of the
# work: "400 No target in combo auto supports tool calling; request carried 29
# tools". Agent work is tool calling, so free tiers cannot serve these agents
# at any price. See the `auto` comment in docker-compose.prod.yml.
#
# UNKEYED IS A NORMAL OUTCOME. If ANTHROPIC_API_KEY is empty the connection is
# created but left disabled, and this script says so instead of failing. The
# router then behaves exactly as it does today.
if api GET /api/provider-nodes | grep -q '"name":"anthropic-direct"'; then
	echo "node anthropic-direct: exists"
else
	cat > /tmp/node2.json <<EOF
{"type":"anthropic","name":"anthropic-direct","apiType":"messages","prefix":"anthropic",
 "baseUrl":"https://api.anthropic.com/v1",
 "chatPath":"/messages","modelsPath":"/models"}
EOF
	echo "node anthropic-direct: $(api POST /api/provider-nodes /tmp/node2.json | head -c 300)"
fi

NODE2_ID=$(api GET /api/provider-nodes \
	| sed 's/},{/}\n{/g' | grep '"name":"anthropic-direct"' \
	| sed 's/.*"id":"\([^"]*\)".*/\1/' | head -1)

if [ -n "${NODE2_ID:-}" ]; then
	if api GET /api/providers | grep -q '"name":"anthropic-direct"'; then
		echo "connection anthropic-direct: exists"
	else
		# `enabled` tracks whether a key was supplied. A provider enabled with
		# an empty credential turns a clean fallback into an auth error and
		# hides the real cause — the failure mode omniroute/README.md warns of.
		if [ -n "${ANTHROPIC_KEY:-}" ]; then EN=true; else EN=false; fi
		cat > /tmp/conn2.json <<EOF
{"provider":"$NODE2_ID","name":"anthropic-direct","apiKey":"$ANTHROPIC_KEY","enabled":$EN}
EOF
		echo "connection anthropic-direct (enabled=$EN): $(api POST /api/providers /tmp/conn2.json | head -c 400)"
	fi
fi

if [ -z "${ANTHROPIC_KEY:-}" ]; then
	echo
	echo "!! TIER 2 IS NOT KEYED — ANTHROPIC_API_KEY is empty in .env."
	echo "!! Every agent request is therefore still billed to the Pro"
	echo "!! subscription. Set it in .env on this machine and re-run."
	echo
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
	-e PW -e PROXY_KEY -e CLAW_KEY -e PREFIX -e ANTHROPIC_KEY \
	-v /tmp/omniroute-provision.sh:/provision.sh:ro \
	alpine:3.21 sh /provision.sh
rm -f /tmp/omniroute-provision.sh
REMOTE
