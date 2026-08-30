#!/bin/sh
# =============================================================================
# heartbeat.sh — prove the subscription still works, hourly. (M11, ADR-0020)
# =============================================================================
#
# THE FAILURE THIS EXISTS FOR
#   The Claude OAuth credential behind cliproxy expires in roughly 7 days. When
#   it does, every agent stops — and stops SILENTLY. A dead agent loop and an
#   idle one look identical from outside: no error, no crash, just a board that
#   never moves. M10 hit exactly this.
#
# WHY NOT AN ORDINARY HTTP CHECK
#   /health answers as long as the process is running. It keeps answering
#   happily with a dead credential, which makes it a check that reports success
#   during the precise outage it was added to catch. So this sends a REAL
#   completion — the smallest one that still exercises auth — and reports
#   healthy only if the model actually answered.
#
# WHY PUSH AND NOT POLL
#   Uptime Kuma is on `apps`; this is on `agent`. Kuma polling into the agent
#   network would also let every code-executing session reach Kuma, which holds
#   the ntfy publish token — the ability to forge an all-clear. Reporting
#   outward keeps the connection direction agent -> apps and widens nothing.
#
# COST — AND WHY THIS NO LONGER SPENDS SUBSCRIPTION TOKENS (M18, ADR-0027)
#   This loop used to send a real completion against tier 1 every hour: ~24/day
#   charged to the Pro subscription whether or not the operator used an agent.
#   That was the only thing consuming the plan while the system sat idle, and
#   the operator asked for it to stop:
#
#     "ensure none of the agents is using the claude pro subscription to run,
#      no heartbeat and nothing. so if i dont use my agents for a day there is
#      no consumption in my claude pro sub"
#
#   HEARTBEAT_MODE selects where the hourly check is billed:
#
#     router (default) — a real completion, sent THROUGH OMNIROUTE against the
#                        tier-2 model. Still a genuine model round-trip, so it
#                        still detects the expiry; the tokens land on the
#                        direct API key instead of the subscription.
#     full             — the old behaviour: tier 1 directly, on the plan.
#     off              — report nothing, spend nothing, monitor nothing.
#
#   A REJECTED ALTERNATIVE, RECORDED SO IT IS NOT RETRIED: checking
#   ${PROXY}/v1/models instead. It is free, and it is useless here. cliproxy
#   answers that from its own static model list without contacting Anthropic —
#   which is why a wrong model id returns 502 rather than an upstream error —
#   and the credential it validates is PROXY_API_KEY, a fixed string in .env
#   that cannot expire. The OAuth credential in the cliproxy_data volume, the
#   one that DOES expire in ~7 days, is never exercised. That check reports
#   healthy throughout the outage it exists to catch: precisely the failure
#   "WHY NOT AN ORDINARY HTTP CHECK" above rejects.
# =============================================================================
set -u

PROXY="http://${PROXY_HOST:-cliproxy}:8317"
INTERVAL="${HEARTBEAT_INTERVAL:-3600}"

# auth | full | off — see the COST section above. Default `auth`: token-free.
HEARTBEAT_MODE="${HEARTBEAT_MODE:-router}"

case "$HEARTBEAT_MODE" in
	router|full|off) ;;
	*)
		# Fail closed, and fail LOUDLY. Silently falling back to `full` on a
		# typo would restore the exact hourly spend this mode exists to stop.
		echo "heartbeat: HEARTBEAT_MODE='${HEARTBEAT_MODE}' is not one of router|full|off" >&2
		exit 1
		;;
esac

if [ "$HEARTBEAT_MODE" = off ]; then
	echo "heartbeat: HEARTBEAT_MODE=off — credential is NOT monitored, and no"
	echo "           tokens are spent. An expired credential will surface as"
	echo "           agents that silently stop working (M10)."
	# sleep forever rather than exit: `restart: unless-stopped` would otherwise
	# restart this container in a tight loop.
	while true; do sleep 86400; done
fi

# Without a push URL there is nothing to report to. That is a misconfiguration,
# not a reason to spin: exit loudly so `docker logs` says why.
# M17: omniroute gets its own push monitor, reported from here.
#
# It sits on `agent`, where Kuma cannot resolve names — an HTTP monitor for it
# reported a permanent outage for a healthy service. This sidecar is already
# on both networks (see the compose comment above, which explains why it is
# the only container that is), so it is the natural place to report from.
#
# NOTE: this is a SEPARATE check, not a by-product of the one below. The
# credential heartbeat talks to cliproxy DIRECTLY, not through the router —
# so a successful completion says nothing about omniroute.
#
# Empty value = that monitor simply goes unreported.
OMNIROUTE_PUSH_URL="${OMNIROUTE_PUSH_URL:-}"
OMNIROUTE="http://${OMNIROUTE_HOST:-omniroute}:20128"

report_omniroute() {
	[ -n "$OMNIROUTE_PUSH_URL" ] || return 0
	# /v1/models needs no completion and costs no tokens, but it does prove the
	# router is serving its API rather than merely holding a port open.
	if wget -qO- --timeout=15 --header="Authorization: Bearer ${OMNIROUTE_API_KEY:-}" \
		"${OMNIROUTE}/v1/models" >/dev/null 2>&1; then
		wget -qO- --timeout=15 "${OMNIROUTE_PUSH_URL}?status=up&msg=ok" >/dev/null 2>&1 || true
	else
		echo "heartbeat: omniroute did not answer /v1/models" >&2
		wget -qO- --timeout=15 "${OMNIROUTE_PUSH_URL}?status=down&msg=no%20answer" >/dev/null 2>&1 || true
	fi
}

if [ -z "${KUMA_PUSH_URL:-}" ]; then
	echo "heartbeat: KUMA_PUSH_URL is not set — the credential will NOT be monitored" >&2
	echo "           mint it in Uptime Kuma (the cliproxy push monitor), then set it in .env" >&2
	exit 1
fi

if [ -z "${PROXY_API_KEY:-}" ]; then
	echo "heartbeat: PROXY_API_KEY is not set — cannot authenticate to the proxy" >&2
	exit 1
fi

echo "heartbeat: reporting to Kuma every ${INTERVAL}s"

while true; do
	case "$HEARTBEAT_MODE" in
	full)
		# Tier 1 DIRECTLY. Spends subscription tokens — the pre-M18 behaviour,
		# now opt-in only.
		#
		# max_tokens:1 — the cheapest request that still forces authentication
		# and a model round-trip. The model id must be one the proxy actually
		# lists at /v1/models. A bare "claude-sonnet-4-5" is NOT among them and
		# returns 502 — verified 2026-08-02, after that guessed id made a
		# working proxy look broken.
		body='{"model":"claude-sonnet-5","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}'
		code="$(wget -qO- --server-response --timeout=60 \
			--header="Content-Type: application/json" \
			--header="Authorization: Bearer ${PROXY_API_KEY}" \
			--post-data="$body" \
			"${PROXY}/v1/chat/completions" 2>&1 | awk '/^  HTTP/{print $2; exit}')"
		;;
	router)
		# THE DEFAULT (M18, ADR-0027). A real completion — so it still catches
		# the expiry that a local endpoint cannot — but sent THROUGH OMNIROUTE
		# against the tier-2 model, so the tokens are billed to the direct API
		# key rather than to the Pro subscription.
		#
		# WHY NOT A TOKEN-FREE GET. An earlier version of this file checked
		# ${PROXY}/v1/models and claimed it cost nothing and still caught the
		# expiry. It does cost nothing, and it does NOT catch the expiry:
		# cliproxy serves that list from its own static config (that is how a
		# wrong model id yields 502 rather than an upstream error), and the key
		# it validates is PROXY_API_KEY — a fixed string in .env that never
		# expires. It never contacts Anthropic at all. It would have reported
		# healthy straight through the outage this monitor exists for, which is
		# exactly the trap "WHY NOT AN ORDINARY HTTP CHECK" above warns about.
		#
		# ⚠️ REQUIRES TIER 2 TO BE KEYED. With ANTHROPIC_API_KEY empty, omniroute
		# has only tier 1 and this falls back onto the subscription — i.e. it
		# silently becomes `full`. verify-subscription-load.sh checks for that
		# combination and fails on it.
		body='{"model":"'"${HEARTBEAT_MODEL:-anthropic/claude-sonnet-5}"'","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}'
		code="$(wget -qO- --server-response --timeout=60 \
			--header="Content-Type: application/json" \
			--header="Authorization: Bearer ${OMNIROUTE_API_KEY:-}" \
			--post-data="$body" \
			"${OMNIROUTE}/v1/chat/completions" 2>&1 | awk '/^  HTTP/{print $2; exit}')"
		;;
	esac

	report_omniroute

	case "$code" in
		2*)
			# Only a real 2xx reports UP. Anything else is left to time out in
			# Kuma, which is correct: silence means trouble.
			wget -qO- --timeout=15 "${KUMA_PUSH_URL}?status=up&msg=ok" >/dev/null 2>&1 \
				|| echo "heartbeat: completion OK but could not reach Kuma" >&2
			;;
		401|403)
			# The expiry, caught. Report DOWN explicitly rather than waiting for
			# a timeout, so the alert names the actual cause.
			echo "heartbeat: proxy rejected the request (HTTP ${code}) — credential likely expired" >&2
			wget -qO- --timeout=15 "${KUMA_PUSH_URL}?status=down&msg=auth%20failed%20${code}" >/dev/null 2>&1 || true
			;;
		*)
			echo "heartbeat: unexpected response (HTTP ${code:-none})" >&2
			wget -qO- --timeout=15 "${KUMA_PUSH_URL}?status=down&msg=http%20${code:-none}" >/dev/null 2>&1 || true
			;;
	esac

	sleep "$INTERVAL"
done
