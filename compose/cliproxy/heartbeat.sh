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
	# max_tokens:1 — the cheapest request that still forces authentication and
	# a model round-trip. A malformed or unauthenticated request fails at the
	# proxy and never reaches the model, which is exactly what must be caught.
	# The model id must be one the proxy actually lists at /v1/models. A bare
	# "claude-sonnet-4-5" is NOT among them and returns 502 — verified
	# 2026-08-02, after that guessed id made a working proxy look broken.
	body='{"model":"claude-sonnet-5","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}'

	code="$(wget -qO- --server-response --timeout=60 \
		--header="Content-Type: application/json" \
		--header="Authorization: Bearer ${PROXY_API_KEY}" \
		--post-data="$body" \
		"${PROXY}/v1/chat/completions" 2>&1 | awk '/^  HTTP/{print $2; exit}')"

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
