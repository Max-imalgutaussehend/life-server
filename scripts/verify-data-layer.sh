#!/usr/bin/env bash
# =============================================================================
# verify-data-layer.sh — prove the M4 data layer's guarantees, on the server.
# =============================================================================
#
# WHY THIS EXISTS
#   ADR-0005 claims each service's role can reach only its own database, and
#   ADR-0004 claims the databases have no route to the internet. Both are
#   claims about things that are easy to believe and easy to get wrong — a
#   missing REVOKE looks identical to a correct setup until the day it doesn't.
#   This script asserts them, so "isolated" is a test result and not a belief.
#
#   It also guards against regression: run it after any change to the init
#   script, the network layout, or a Postgres major upgrade.
#
# WHERE IT RUNS
#   On the server, as deploy. `make verify-data` copies it over and runs it.
#
# WHAT A FAILURE MEANS
#   Any FAIL below is a real isolation defect. Do not deploy a service that
#   holds data until it is understood.
#
# EXIT CODE
#   0 = every assertion held. 1 = at least one FAIL.
# =============================================================================
set -uo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/opt/life-server}"
PG="${PG_CONTAINER:-prod-postgres}"
RD="${REDIS_CONTAINER:-prod-redis}"

pass=0
fail=0

ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }

# Secrets come from the server's .env; never echoed.
set -a
# shellcheck disable=SC1091  # server-side path, not resolvable at lint time
. "${COMPOSE_DIR}/.env"
set +a

SERVICES=(n8n paperclip hermes)

# --- 1. Each role reaches its OWN database ----------------------------------
echo "== each role can reach its own database =="
for svc in "${SERVICES[@]}"; do
	var="POSTGRES_${svc^^}_PASSWORD"
	if docker exec -e PGPASSWORD="${!var}" "$PG" \
		psql -U "$svc" -d "$svc" -h 127.0.0.1 -tAc 'SELECT 1' >/dev/null 2>&1; then
		ok "$svc -> $svc"
	else
		bad "$svc cannot reach its own database $svc"
	fi
done

# --- 2. Each role is REFUSED every other database ---------------------------
# The heart of ADR-0005. A pass here means the REVOKE ... FROM PUBLIC took
# effect; a fail means any compromised service can read the others' data.
echo "== each role is refused every other database =="
for svc in "${SERVICES[@]}"; do
	var="POSTGRES_${svc^^}_PASSWORD"
	for other in "${SERVICES[@]}"; do
		[[ "$svc" == "$other" ]] && continue
		if docker exec -e PGPASSWORD="${!var}" "$PG" \
			psql -U "$svc" -d "$other" -h 127.0.0.1 -tAc 'SELECT 1' >/dev/null 2>&1; then
			bad "$svc CAN reach $other — cross-service isolation is broken"
		else
			ok "$svc -> $other refused"
		fi
	done
done

# --- 3. Per-role connection limits are set ----------------------------------
# Without these one leaking service can exhaust max_connections for all.
echo "== per-role connection limits =="
for svc in "${SERVICES[@]}"; do
	limit=$(docker exec "$PG" psql -U "$POSTGRES_SUPER_USER" -tAc \
		"SELECT rolconnlimit FROM pg_roles WHERE rolname='$svc'" 2>/dev/null | tr -d '[:space:]')
	if [[ "$limit" =~ ^[0-9]+$ ]] && [[ "$limit" -gt 0 ]]; then
		ok "$svc CONNECTION LIMIT = $limit"
	else
		bad "$svc has no connection limit (got '${limit:-empty}')"
	fi
done

# --- 4. PUBLIC has no CONNECT on service databases --------------------------
echo "== PUBLIC connect revoked =="
for svc in "${SERVICES[@]}"; do
	if docker exec "$PG" psql -U "$POSTGRES_SUPER_USER" -tAc \
		"SELECT has_database_privilege('public', '$svc', 'CONNECT')" 2>/dev/null \
		| tr -d '[:space:]' | grep -qx 'f'; then
		ok "PUBLIC cannot connect to $svc"
	else
		bad "PUBLIC can still connect to $svc"
	fi
done

# --- 5. Redis requires authentication ---------------------------------------
# Redis' only access control. If an unauthenticated PING succeeds, anything on
# net-data can read every service's queue and cache.
echo "== redis authentication =="
if docker exec "$RD" redis-cli ping 2>&1 | grep -qi 'NOAUTH\|Authentication required'; then
	ok "unauthenticated access refused"
else
	bad "redis answered without a password"
fi

if docker exec "$RD" redis-cli --no-auth-warning -a "$REDIS_PASSWORD" ping 2>/dev/null \
	| grep -qx 'PONG'; then
	ok "authenticated access works"
else
	bad "redis rejects the password in .env"
fi

# --- 6. Destructive commands disabled --------------------------------------
echo "== redis destructive commands disabled =="
for cmd in FLUSHALL FLUSHDB CONFIG; do
	if docker exec "$RD" redis-cli --no-auth-warning -a "$REDIS_PASSWORD" \
		"$cmd" 2>&1 | grep -qi 'unknown command'; then
		ok "$cmd is disabled"
	else
		bad "$cmd is still callable"
	fi
done

# --- 7. No published ports on the data layer -------------------------------
# ADR-0003/0004: neither database may be reachable from the host or the world.
echo "== no published ports =="
for c in "$PG" "$RD"; do
	ports=$(docker inspect "$c" --format '{{json .NetworkSettings.Ports}}' 2>/dev/null)
	if ! grep -q 'HostPort' <<<"$ports"; then
		ok "$c publishes no host port"
	else
		bad "$c publishes a port: $ports"
	fi
done

# --- 8. The data network has no route out ----------------------------------
# `internal: true` means a compromised database cannot exfiltrate or phone home.
echo "== data network is internal =="
net=$(docker network ls --filter name=net-data --format '{{.Name}}' | head -1)
if [[ -n "$net" ]] && \
	[[ "$(docker network inspect "$net" --format '{{.Internal}}')" == "true" ]]; then
	ok "$net is internal"
else
	bad "${net:-net-data} is NOT internal — databases can reach the internet"
fi

# --- 9. Databases are not on the edge network ------------------------------
# Being on `edge` would put a database one proxy misconfiguration from the
# internet.
echo "== databases are off the edge network =="
for c in "$PG" "$RD"; do
	if docker inspect "$c" \
		--format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' \
		2>/dev/null | grep -q 'net-edge'; then
		bad "$c is attached to net-edge"
	else
		ok "$c is not on net-edge"
	fi
done

# --- 10. No plaintext password in the container logs ----------------------
# postgresql.conf logs DDL, and CREATE ROLE ... PASSWORD is DDL. The init
# script suppresses logging for its own session; this proves it worked.
echo "== no plaintext passwords in postgres logs =="
if docker logs "$PG" 2>&1 | grep -q 'PASSWORD .'; then
	bad "a password appears in the postgres container log"
else
	ok "no password in the container log"
fi

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]] || exit 1
