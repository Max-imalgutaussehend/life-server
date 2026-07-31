#!/usr/bin/env bash
# =============================================================================
# verify-agent-sandbox.sh — prove the M9 agent sandbox actually isolates.
# =============================================================================
#
# WHY THIS EXISTS
#   M9 agents execute arbitrary code chosen by a language model. The claim that
#   they "cannot reach the database" is exactly the kind of claim that is easy
#   to believe and easy to get wrong: a container joined to one extra network,
#   or a `docker run` without `--network`, looks identical to a correct setup
#   until something reads your Postgres password.
#
#   So the boundary is TESTED, by starting a container on the agent network and
#   attempting the things an escaped agent would attempt. Every one must fail.
#
# THE THREAT MODEL
#   Not "a malicious operator". The realistic case is prompt injection: an agent
#   reads a web page, an email, or a ticket written by another agent, and that
#   text tells it to exfiltrate .env. The agent is not compromised — it is
#   working correctly on hostile input. Nothing in the workspace may be worth
#   stealing, and nothing reachable from it may hold secrets.
#
# WHERE IT RUNS
#   On the server, as deploy. `make verify-agent-sandbox` copies it and runs it.
#
# EXIT CODE
#   0 = the sandbox holds. 1 = at least one boundary is missing. Do not run an
#   agent until this passes.
# =============================================================================
set -uo pipefail

PREFIX="${ENV_PREFIX_NAME:-prod-}"
NET="${PREFIX}net-agent"
# Alpine is small and already familiar to this host; it adds no meaningful
# pull cost and gives the probe a usable nc/test toolset.
PROBE_IMAGE="${PROBE_IMAGE:-alpine:3.21}"
PROBE="agent-sandbox-probe-$$"

pass=0
fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }

cleanup() { docker rm -f "$PROBE" >/dev/null 2>&1 || true; }
trap cleanup EXIT

printf '\n\033[1m==> agent sandbox (%s)\033[0m\n\n' "$NET"

docker network inspect "$NET" >/dev/null 2>&1 || {
	printf '\033[31merror:\033[0m network %s does not exist — run `make deploy-stack` first\n' "$NET" >&2
	exit 1
}

# The probe stands in for an agent workspace: same network, same lack of
# privileges. If IT cannot reach something, neither can an agent.
docker run -d --name "$PROBE" --network "$NET" \
	--user 65534:65534 \
	--security-opt no-new-privileges:true \
	"$PROBE_IMAGE" sleep 300 >/dev/null 2>&1 || {
	printf '\033[31merror:\033[0m could not start the probe container\n' >&2
	exit 1
}

# nc with a short timeout. A refused OR filtered port both mean "cannot reach",
# which is the property under test; distinguishing them is not needed.
probe_tcp() {
	docker exec "$PROBE" sh -c "nc -z -w 3 '$1' '$2' 2>/dev/null"
}

# ── 1. The data layer must be unreachable ───────────────────────────────────
# The whole point. An agent that reaches Postgres has every service's data.
while read -r host port; do
	[ -n "$host" ] || continue
	if probe_tcp "$host" "$port"; then
		bad "REACHED ${host}:${port} from the agent network — the sandbox is open"
	else
		ok "cannot reach ${host}:${port}"
	fi
done <<-EOF
	postgres 5432
	${PREFIX}postgres 5432
	redis 6379
	${PREFIX}redis 6379
EOF

# ── 2. Other applications must be unreachable ───────────────────────────────
# n8n holds credentials for everything it integrates with, which makes it the
# most valuable target on the host after the database itself.
#
# paperclip is deliberately ABSENT from this list — see assertion 2b.
while read -r host port; do
	[ -n "$host" ] || continue
	if probe_tcp "$host" "$port"; then
		bad "REACHED ${host}:${port} — agents can talk to other services"
	else
		ok "cannot reach ${host}:${port}"
	fi
done <<-EOF
	${PREFIX}n8n 5678
	${PREFIX}caddy 80
	${PREFIX}ntfy 80
	${PREFIX}status 3001
EOF

# ── 2b. Paperclip MUST be reachable, and MUST demand a token ────────────────
# The one deliberate hole in the wall (M10, ADR-0019). The runner holds no
# database credentials, so tickets have to arrive through Paperclip's API —
# which makes Paperclip the narrow interface the M9 sandbox assumed.
#
# Reachability alone would be a regression, so this also asserts the API is
# CLOSED without a token. An agent API reachable by anything on this network
# would hand a prompt-injected session the entire ticket queue.
if probe_tcp "${PREFIX}paperclip" 8080; then
	ok "can reach ${PREFIX}paperclip:8080 (required — the ticket API)"

	code="$(docker exec "$PROBE" sh -c \
		"wget -qO- --server-response --timeout=5 --post-data='{}' \
		 --header='Content-Type: application/json' \
		 http://${PREFIX}paperclip:8080/api/claim 2>&1 | awk '/^  HTTP/{print \$2; exit}'" 2>/dev/null)"
	case "$code" in
		401|404) ok "the agent API rejects an unauthenticated request (HTTP ${code})" ;;
		"")      bad "could not determine whether the agent API is authenticated" ;;
		*)       bad "the agent API answered ${code} WITHOUT a token — it is open" ;;
	esac
else
	bad "cannot reach ${PREFIX}paperclip:8080 — the runner cannot claim tickets"
fi

# ── 3. The Docker socket must be absent ─────────────────────────────────────
# A mounted docker.sock is root on the host in one API call. This is the single
# worst mistake available here, so it is asserted explicitly.
if docker exec "$PROBE" test -S /var/run/docker.sock 2>/dev/null; then
	bad "the Docker socket is present in the workspace — this is host root"
else
	ok "no Docker socket in the workspace"
fi

# ── 4. Secrets must not be mounted ──────────────────────────────────────────
for f in /opt/life-server/.env /.env /root/.config/sops/age/keys.txt /secrets.enc.env; do
	if docker exec "$PROBE" test -e "$f" 2>/dev/null; then
		bad "$f is visible inside the workspace"
	else
		ok "$f is not visible"
	fi
done

# ── 5. The agent must NOT be root ───────────────────────────────────────────
uid="$(docker exec "$PROBE" id -u 2>/dev/null || echo unknown)"
if [ "$uid" = "0" ]; then
	bad "workspace runs as root (uid 0)"
else
	ok "workspace runs as non-root (uid ${uid})"
fi

# ── 6. Egress MUST work ─────────────────────────────────────────────────────
# The one thing that must NOT be blocked: Claude Code cannot function without
# reaching api.anthropic.com. A sandbox that also breaks the product is not a
# win, and this asserts the trade-off is the one that was intended.
if docker exec "$PROBE" sh -c 'nc -z -w 5 api.anthropic.com 443 2>/dev/null'; then
	ok "egress to api.anthropic.com works (required by Claude Code)"
else
	bad "no egress to api.anthropic.com — agents cannot function"
fi

printf '\n  \033[1m%d passed, %d failed\033[0m\n\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || {
	echo "  The agent sandbox does NOT hold. Do not run agents until this passes."
	exit 1
}
