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
# COST
#   One minimal completion per hour, ~24/day. Negligible against a subscription,
#   and the alternative is discovering the outage days late.
# =============================================================================
set -u

PROXY="http://${PROXY_HOST:-cliproxy}:8317"
INTERVAL="${HEARTBEAT_INTERVAL:-3600}"

# Without a push URL there is nothing to report to. That is a misconfiguration,
# not a reason to spin: exit loudly so `docker logs` says why.
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
	# max_tokens:1 — the cheapest request that still forces authentication and
	# a model round-trip. A malformed or unauthenticated request fails at the
	# proxy and never reaches the model, which is exactly what must be caught.
	body='{"model":"claude-sonnet-4-5","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}'

	code="$(wget -qO- --server-response --timeout=60 \
		--header="Content-Type: application/json" \
		--header="Authorization: Bearer ${PROXY_API_KEY}" \
		--post-data="$body" \
		"${PROXY}/v1/chat/completions" 2>&1 | awk '/^  HTTP/{print $2; exit}')"

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
