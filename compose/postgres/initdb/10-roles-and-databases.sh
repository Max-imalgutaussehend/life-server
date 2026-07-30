#!/bin/bash
# =============================================================================
# 10-roles-and-databases.sh — one database + one role per service (ADR-0005)
# =============================================================================
#
# WHY A SCRIPT AND NOT MANUAL psql
#   Provisioning by hand means the server's state exists nowhere in Git. This
#   runs automatically on first start of an empty data directory, so the role
#   layout is reproducible: destroy the volume, start again, same result.
#
# WHAT IT GUARANTEES
#   - each service owns exactly one database
#   - each service's role can connect ONLY to its own database
#   - PUBLIC connect rights are revoked, so a new role cannot read others
#   - a connection limit per role, so one leaking service cannot exhaust
#     max_connections for everyone (the main risk of a shared instance)
#
# IDEMPOTENCY
#   Postgres only runs /docker-entrypoint-initdb.d on an EMPTY data dir, so
#   this executes once. The guards below still make re-running safe if it is
#   ever invoked manually — which is exactly how a service added in a later
#   milestone gets provisioned without destroying the volume:
#
#     docker compose exec postgres \
#       /docker-entrypoint-initdb.d/10-roles-and-databases.sh
#
# WHICH SERVICES ARE PROVISIONED
#   Driven by POSTGRES_SERVICES, which the compose file sets rather than this
#   script restating the service list (ADR-0014). A service with no password
#   in .env is skipped with a warning, not silently ignored.
# =============================================================================
set -euo pipefail

# Per-role cap. Sized so all services together stay well under max_connections
# (100 by default) with headroom for maintenance sessions.
CONN_LIMIT=20

# The bootstrap superuser. The official image exposes it as POSTGRES_USER;
# .env calls it POSTGRES_SUPER_USER (ADR-0006 naming). Accept either so the
# script works both under the entrypoint and when invoked by hand.
SUPER="${POSTGRES_USER:-${POSTGRES_SUPER_USER:-postgres}}"

# Services needing a database. Space-separated, set by the compose file.
SERVICES="${POSTGRES_SERVICES:-n8n paperclip hermes}"

skipped=0

create_service_db() {
	local svc="$1"

	# Password lives in .env as POSTGRES_<SVC>_PASSWORD. Uppercased, with
	# dashes mapped to underscores so a service named `foo-bar` resolves to
	# POSTGRES_FOO_BAR_PASSWORD.
	local var="POSTGRES_${svc//-/_}_PASSWORD"
	var="${var^^}"
	local pass="${!var:-}"

	if [[ -z "$pass" || "$pass" == "__GENERATE__" ]]; then
		# Loud, and counted. A silently missing database surfaces much later
		# as an application failing to start, far from the real cause.
		echo "  WARN ${svc}: ${var} unset in .env — not provisioned"
		skipped=$((skipped + 1))
		return 0
	fi

	echo "  provisioning ${svc}"

	# Role first: the database is created with the role as owner, so the role
	# must already exist. Identifiers and the password go through psql
	# variables and format()'s %I/%L, never raw string interpolation, so a
	# quote in a generated secret cannot break out of the statement.
	#
	# log_statement/log_min_duration_statement are disabled FOR THIS SESSION
	# ONLY. postgresql.conf sets log_statement='ddl' so real schema changes are
	# never a mystery — but CREATE ROLE ... PASSWORD is DDL, so that setting
	# would write all three service passwords in plaintext into the container
	# log, where `docker logs` and the on-disk json.log expose them to anyone
	# who can read either. The SET is session-scoped and does not weaken the
	# global policy.
	psql -v ON_ERROR_STOP=1 --username "$SUPER" --dbname postgres \
		-v svc="$svc" -v pass="$pass" -v climit="$CONN_LIMIT" <<-'SQL'
			SET log_statement = 'none';
			SET log_min_duration_statement = -1;
			SELECT format(
				CASE WHEN EXISTS (SELECT FROM pg_roles WHERE rolname = :'svc')
					THEN 'ALTER ROLE %I LOGIN PASSWORD %L CONNECTION LIMIT %s'
					ELSE 'CREATE ROLE %I LOGIN PASSWORD %L CONNECTION LIMIT %s'
				END, :'svc', :'pass', :'climit'::int)
			\gexec
		SQL

	if ! psql -tAq --username "$SUPER" --dbname postgres \
		-c "SELECT 1 FROM pg_database WHERE datname='${svc}'" | grep -q 1; then
		createdb --username "$SUPER" --owner "${svc}" "${svc}"
	fi

	psql -v ON_ERROR_STOP=1 --username "$SUPER" --dbname "${svc}" \
		-v svc="$svc" <<-'SQL'
			-- Without this, ANY role could connect to this database: PostgreSQL
			-- grants CONNECT to PUBLIC by default. This is the line that
			-- actually isolates services from each other.
			REVOKE ALL ON DATABASE :"svc" FROM PUBLIC;
			GRANT ALL PRIVILEGES ON DATABASE :"svc" TO :"svc";

			-- Same reasoning for the public schema: PostgreSQL 15+ already
			-- restricts it, but being explicit survives version changes.
			REVOKE ALL ON SCHEMA public FROM PUBLIC;
			GRANT ALL ON SCHEMA public TO :"svc";
		SQL
}

echo "=== provisioning per-service databases (ADR-0005) ==="
for svc in $SERVICES; do
	create_service_db "$svc"
done

if [[ $skipped -gt 0 ]]; then
	echo "=== done, but ${skipped} service(s) NOT provisioned (see WARN above) ==="
else
	echo "=== done: ${SERVICES} ==="
fi
