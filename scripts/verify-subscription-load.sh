#!/usr/bin/env bash
# =============================================================================
# verify-subscription-load.sh — is agent load actually off the Pro subscription?
# =============================================================================
#
# THE FAILURE THIS CATCHES
#   Every agent path already points at omniroute, so the wiring LOOKS correct
#   and reviews as correct. But a router with one tier is not a router: while
#   ANTHROPIC_API_KEY is empty, every fallback lands back on the subscription
#   and the Pro plan is consumed exactly as if omniroute were not there.
#
#   That state is invisible in the compose file, which is why it needs a test.
#
# Local only — no SSH, no server. Safe to run from a machine with no uplink.
# Exit 0 = load can leave the subscription. Exit 1 = it cannot.
# =============================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO/.env}"
COMPOSE="$REPO/compose/docker-compose.prod.yml"
fail=0

say()  { printf '%s\n' "$*"; }
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }

say "── agent routing ─────────────────────────────────────────────"

# 1. No agent may bypass the router by talking to cliproxy directly.
#    (cliproxy's OWN service block legitimately names itself, so only
#    *_BASE_URL assignments are inspected.)
if grep -nE '^[[:space:]]*(ANTHROPIC|OPENAI|LM)_BASE_URL:' "$COMPOSE" \
   | grep -q 'cliproxy'; then
	bad "a *_BASE_URL still points at cliproxy — that path bypasses the router"
	grep -nE '^[[:space:]]*(ANTHROPIC|OPENAI|LM)_BASE_URL:' "$COMPOSE" \
		| grep 'cliproxy' | sed 's/^/        /'
else
	ok "no agent bypasses the router"
fi

# 2. Every base URL that exists should be the router.
n=$(grep -cE '^[[:space:]]*(ANTHROPIC|OPENAI|LM)_BASE_URL:.*omniroute' "$COMPOSE" || true)
if [ "$n" -ge 4 ]; then
	ok "$n agent base URLs route through omniroute"
else
	bad "only $n base URLs route through omniroute (expected >= 4)"
fi

say "── idle consumption (M18) ────────────────────────────────────"

# THE PROPERTY UNDER TEST: with nobody using an agent, nothing calls a model.
# Every agent here is reactive — openclaw waits for WhatsApp/Telegram, hermes
# and the paperclip workers wait for the board. The heartbeat was the sole
# exception, and it ran hourly forever.
HB="$REPO/compose/cliproxy/heartbeat.sh"

mode="router"
if [ -f "$ENV_FILE" ]; then
	m=$(grep -E '^HEARTBEAT_MODE=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)
	[ -n "$m" ] && mode="$m"
fi

# The heartbeat sends a REAL completion in every mode except `off` — the
# token-free GET was removed because it never touched the expiring OAuth
# credential (see the rejected-alternative note in heartbeat.sh). So the
# question is not "does it spend?" but "WHOSE budget does it spend?", and in
# `router` mode that depends entirely on tier 2 being keyed. Unkeyed, `router`
# degrades silently into `full`. That combination is the whole bug, so it is
# checked here rather than left to the reader.
case "$mode" in
	off)    ok  "heartbeat mode '$mode' — nothing is sent (and nothing is monitored)" ;;
	router)
		if [ -f "$ENV_FILE" ] && \
		   [ -n "$(grep -E '^ANTHROPIC_API_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2-)" ]; then
			ok  "heartbeat mode 'router' — hourly completion billed to tier 2, not the plan"
		else
			bad "heartbeat mode 'router' with tier 2 UNKEYED — falls back to the"
			say "        subscription, so this is ~24 completions/day on the Pro plan."
			say "        Either key ANTHROPIC_API_KEY, or set HEARTBEAT_MODE=off."
		fi ;;
	full)   bad "heartbeat mode 'full' — ~24 real completions/day billed to the plan"
	        say "        set HEARTBEAT_MODE=off (or key tier 2 and use 'router')" ;;
	*)      bad "heartbeat mode '$mode' is not one of router|full|off"
	        say "        NOTE: 'auth' was REMOVED — the script exits 1 on it." ;;
esac

# Guard against the mode being bypassed: a completion call outside the `full`
# branch would spend tokens regardless of what the mode says.
if [ -f "$HB" ]; then
	if grep -q 'HEARTBEAT_MODE' "$HB"; then
		ok "heartbeat honours HEARTBEAT_MODE"
	else
		bad "heartbeat.sh ignores HEARTBEAT_MODE — the setting above does nothing"
	fi
fi

# Nothing else may sit in a loop calling a model. verify-agent-sandbox.sh also
# sends a completion, but only when the operator runs it by hand.
loops=$(grep -rlE 'while true' "$REPO/compose" "$REPO/scripts" 2>/dev/null \
	| xargs grep -lE 'chat/completions|/v1/messages' 2>/dev/null \
	| grep -vE 'heartbeat\.sh|verify-subscription-load\.sh' || true)
if [ -n "$loops" ]; then
	bad "an unattended loop calls a model:"
	printf '        %s\n' $loops
else
	ok "no other unattended loop calls a model"
fi

say ""
say "── where the router can send it ──────────────────────────────"

if [ ! -f "$ENV_FILE" ]; then
	bad "no .env at $ENV_FILE — cannot tell whether tier 2 is keyed"
else
	key=$(grep -E '^ANTHROPIC_API_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)
	if [ -n "$key" ]; then
		ok "tier 2 is keyed — fallback leaves the subscription"
	else
		bad "tier 2 is NOT keyed (ANTHROPIC_API_KEY empty in .env)"
		say ""
		say "        omniroute has exactly one tier to route to, so every"
		say "        agent request is billed to the Pro subscription."
		say ""
		say "        Fix:  1. put ANTHROPIC_API_KEY=sk-ant-… in .env"
		say "              2. ./scripts/omniroute-providers.sh"
		say ""
		say "        The free-provider pool is NOT an alternative: it cannot"
		say "        do tool calling, and agent work is tool calling."
		say "        (ADR-0021, and the \`auto\` comment in the compose file.)"
	fi
fi

say ""
if [ "$fail" -eq 0 ]; then
	say "PASS — idle costs nothing, and agent load can leave the subscription."
else
	say "FAIL — agent load is still on the Pro subscription."
fi
exit "$fail"
