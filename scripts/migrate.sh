#!/usr/bin/env bash
# =============================================================================
# migrate.sh — apply SQL migrations to a service's database. (M9)
# =============================================================================
#
# WHY THIS EXISTS
#   compose/postgres/initdb/ only runs when the Postgres volume is EMPTY. Once
#   a database exists — which it has since M4 — that directory can never
#   deliver another change. Without a migration path, schema changes become
#   hand-typed psql, which is unreproducible and unreviewable, and the repo
#   stops describing the system.
#
# WHAT IT GUARANTEES
#   - Each migration runs exactly once (tracked in schema_migrations).
#   - Applied migrations are CHECKSUMMED. Editing a file that already ran is a
#     hard error, because the database and the repository would silently
#     disagree about what the schema is.
#   - Migrations run as the SERVICE role, not the superuser, so objects belong
#     to the role that has to live with them (ADR-0005).
#   - Each file wraps its own BEGIN/COMMIT, so a failure leaves the database at
#     the last good migration rather than half-applied.
#
# WHERE IT RUNS
#   On the server, as deploy. `make migrate` copies it over and runs it.
#
# USAGE
#   ./migrate.sh <database>             apply pending migrations
#   ./migrate.sh <database> --status    show applied and pending
#   ./migrate.sh <database> --dry-run   list what WOULD run, change nothing
# =============================================================================
set -uo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/opt/life-server}"
PG="${PG_CONTAINER:-prod-postgres}"

DB="${1:-}"
MODE="${2:-apply}"

die() { printf '\033[31merror:\033[0m %s\n' "$1" >&2; exit 1; }
ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; }
info(){ printf '  \033[2m%s\033[0m\n' "$1"; }

[ -n "$DB" ] || die "usage: migrate.sh <database> [--status|--dry-run]"

MIG_DIR="${COMPOSE_DIR}/compose/postgres/migrations/${DB}"
[ -d "$MIG_DIR" ] || die "no migrations directory for '${DB}' (looked in ${MIG_DIR})"

# The service role's password. Read from the server's .env, never echoed.
set -a
# shellcheck disable=SC1091  # server-side path, not resolvable at lint time
. "${COMPOSE_DIR}/.env"
set +a

PW_VAR="POSTGRES_$(printf '%s' "$DB" | tr '[:lower:]' '[:upper:]')_PASSWORD"
PW="${!PW_VAR:-}"
[ -n "$PW" ] || die "${PW_VAR} is not set in ${COMPOSE_DIR}/.env"

# psql as the SERVICE role. ON_ERROR_STOP is what makes a failed statement fail
# the script instead of continuing through a broken migration.
psql_svc() {
	docker exec -i -e PGPASSWORD="$PW" "$PG" \
		psql -v ON_ERROR_STOP=1 --username "$DB" --dbname "$DB" "$@"
}

psql_svc -c 'SELECT 1' >/dev/null 2>&1 \
	|| die "cannot connect to '${DB}' as role '${DB}' — is the stack up?"

# The ledger lives inside the service's own database, so a database restored
# from backup carries its migration history with it.
psql_svc -q <<-'SQL' >/dev/null || die "could not create schema_migrations"
	CREATE TABLE IF NOT EXISTS schema_migrations (
		filename   text PRIMARY KEY,
		checksum   text        NOT NULL,
		applied_at timestamptz NOT NULL DEFAULT now()
	);
SQL

shopt -s nullglob
files=("${MIG_DIR}"/*.sql)
shopt -u nullglob
[ ${#files[@]} -gt 0 ] || die "no .sql files in ${MIG_DIR}"

printf '\n\033[1m==> %s\033[0m  (%d migration files)\n' "$DB" "${#files[@]}"

applied=0
pending=0
drift=0

for f in "${files[@]}"; do
	name="$(basename "$f")"
	sum="$(sha256sum "$f" | cut -d' ' -f1)"

	recorded="$(psql_svc -tAc \
		"SELECT checksum FROM schema_migrations WHERE filename = '${name}'" 2>/dev/null)"

	if [ -n "$recorded" ]; then
		if [ "$recorded" != "$sum" ]; then
			# The file changed after being applied. The database reflects the OLD
			# content and nothing will ever re-run it, so the repo now lies about
			# the schema. Fix with a NEW migration, never by editing this one.
			printf '  \033[31mDRIFT\033[0m %s — applied content differs from the file on disk\n' "$name"
			drift=$((drift + 1))
		elif [ "$MODE" = "--status" ]; then
			ok "$name (applied)"
		fi
		applied=$((applied + 1))
		continue
	fi

	pending=$((pending + 1))

	if [ "$MODE" = "--status" ] || [ "$MODE" = "--dry-run" ]; then
		printf '  \033[33mPENDING\033[0m %s\n' "$name"
		continue
	fi

	printf '  applying %s ... ' "$name"
	if ! psql_svc -q < "$f" >/dev/null; then
		printf '\033[31mFAILED\033[0m\n'
		die "migration ${name} failed — database left at the previous migration"
	fi

	# Recorded only after the migration itself succeeded. A crash between the
	# two leaves it applied but unrecorded, so it would run again — which is
	# exactly why every migration is written to be idempotent.
	psql_svc -q -c \
		"INSERT INTO schema_migrations (filename, checksum) VALUES ('${name}', '${sum}')" \
		>/dev/null || die "applied ${name} but could not record it"

	printf '\033[32mok\033[0m\n'
done

echo
if [ "$drift" -gt 0 ]; then
	printf '\033[31m%d migration(s) were edited after being applied.\033[0m\n' "$drift"
	echo "The database does NOT match the repository. Write a new migration to"
	echo "reconcile it — editing an applied file cannot fix this."
	exit 1
fi

case "$MODE" in
	--status|--dry-run) info "${applied} applied, ${pending} pending" ;;
	*)                  info "${applied} already applied, ${pending} newly applied" ;;
esac
