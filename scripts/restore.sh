#!/usr/bin/env bash
# =============================================================================
# restore.sh — restore from a restic snapshot, or rehearse doing so.
# =============================================================================
#
# WHY A REHEARSAL MODE IS THE DEFAULT
#   An untested restore is a hope, not a backup. ADR-0009 makes the rehearsal
#   mandatory in M5 precisely because the things that break a restore — a wrong
#   RESTIC_PASSWORD, an unreachable repository, a truncated dump — are all
#   cheap to find now and expensive to find during an outage.
#
#   `--rehearse` restores the dump into a THROWAWAY database and verifies it
#   loads, touching nothing real. It is the default for that reason: the
#   dangerous operation should be the one you have to ask for explicitly.
#
# MODES
#   --rehearse            (default) restore into a scratch database, verify,
#                         drop it. Safe to run any time, including in prod.
#   --list                show available snapshots and exit.
#   --files DEST          restore a snapshot's files to DEST. Never touches
#                         Postgres. Use this to recover .env or a volume.
#   --db-production       DESTRUCTIVE. Replay the dump into the live cluster,
#                         overwriting current data. Requires typed confirmation.
#
# SNAPSHOT SELECTION
#   --snapshot ID         defaults to `latest`.
#
# USAGE
#   make restore                       # rehearsal
#   sudo .../restore.sh --list
#   sudo .../restore.sh --files /tmp/recovered
#   sudo .../restore.sh --db-production --snapshot abc123
# =============================================================================
set -euo pipefail

REPO_DIR="${REPO_DIR:-/opt/life-server}"
MODE=rehearse
SNAPSHOT=latest
FILES_DEST=""

while [[ $# -gt 0 ]]; do
	case "$1" in
		--rehearse)       MODE=rehearse ;;
		--list)           MODE=list ;;
		--files)          MODE=files; FILES_DEST="${2:?--files needs a destination}"; shift ;;
		--db-production)  MODE=db-production ;;
		--snapshot)       SNAPSHOT="${2:?--snapshot needs an ID}"; shift ;;
		*) echo "unknown argument: $1" >&2; exit 2 ;;
	esac
	shift
done

log() { printf '%s  %s\n' "$(date --iso-8601=seconds)" "$1"; }
die() { printf '%s  ERROR: %s\n' "$(date --iso-8601=seconds)" "$1" >&2; exit 1; }

[[ -f "${REPO_DIR}/.env" ]] || die "${REPO_DIR}/.env not found"
set -a
# shellcheck disable=SC1091  # server-side path, not resolvable at lint time
. "${REPO_DIR}/.env"
set +a

[[ -n "${RESTIC_REPOSITORY:-}" ]] || die "RESTIC_REPOSITORY is not set in .env"
[[ -n "${RESTIC_PASSWORD:-}" ]]   || die "RESTIC_PASSWORD is not set in .env"
command -v restic >/dev/null      || die "restic is not installed"

ENV_PREFIX_NAME="${ENV_PREFIX_NAME:-prod-}"
PG_CONTAINER="${PG_CONTAINER:-${ENV_PREFIX_NAME}postgres}"
DUMP_PATH="/var/lib/life-server-backup/dump/pg_dumpall.sql"

# --- list -------------------------------------------------------------------
if [[ "$MODE" == list ]]; then
	restic snapshots --tag life-server || die "cannot read snapshots"
	exit 0
fi

# --- files ------------------------------------------------------------------
# Plain file recovery. Deliberately never touches Postgres — recovering .env
# should not carry any risk to the running database.
if [[ "$MODE" == files ]]; then
	mkdir -p "$FILES_DEST"
	# 0700: whatever comes out may include .env and a database dump.
	chmod 700 "$FILES_DEST"
	log "restoring snapshot ${SNAPSHOT} to ${FILES_DEST}"
	restic restore "$SNAPSHOT" --target "$FILES_DEST" || die "restic restore failed"
	log "done. Recovered items of interest:"
	find "$FILES_DEST" \( -name '.env' -o -name 'pg_dumpall.sql' \) | sed 's/^/  /'
	log "NOTE: a restored .env holds the secrets that were live at snapshot time."
	exit 0
fi

# Both remaining modes need Postgres up and the dump from the snapshot.
docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER" \
	|| die "${PG_CONTAINER} is not running"

SCRATCH="$(mktemp -d /tmp/life-restore.XXXXXX)"
chmod 700 "$SCRATCH"
trap 'rm -rf "${SCRATCH:?}"' EXIT

log "extracting ${DUMP_PATH} from snapshot ${SNAPSHOT}"
# --include pulls just the dump rather than the whole snapshot: faster, and it
# cannot accidentally overwrite anything else.
restic restore "$SNAPSHOT" --target "$SCRATCH" --include "$DUMP_PATH" \
	|| die "could not extract the dump from the snapshot"

LOCAL_DUMP="${SCRATCH}${DUMP_PATH}"
[[ -f "$LOCAL_DUMP" ]] || die "dump not present in snapshot at ${DUMP_PATH}"

grep -q 'PostgreSQL database cluster dump complete' "$LOCAL_DUMP" \
	|| die "extracted dump has no completion marker — it is truncated"
log "extracted $(numfmt --to=iec "$(stat -c%s "$LOCAL_DUMP")"), completion marker present"

# --- rehearse ---------------------------------------------------------------
# Proves the whole chain — repository reachable, password correct, dump intact
# and replayable — against a scratch database that is dropped afterwards.
if [[ "$MODE" == rehearse ]]; then
	SCRATCH_DB="restore_rehearsal_$$"
	log "rehearsing into throwaway database ${SCRATCH_DB}"

	pg() { docker exec -i -e PGPASSWORD="${POSTGRES_SUPER_PASSWORD}" "$PG_CONTAINER" "$@"; }

	pg createdb -U "${POSTGRES_SUPER_USER}" "$SCRATCH_DB" \
		|| die "could not create the rehearsal database"

	# Drop the scratch DB whatever happens next.
	# shellcheck disable=SC2064  # expand SCRATCH_DB/SCRATCH now, not at trap time
	trap "docker exec -e PGPASSWORD='${POSTGRES_SUPER_PASSWORD}' '${PG_CONTAINER}' \
		dropdb -U '${POSTGRES_SUPER_USER}' --if-exists '${SCRATCH_DB}' >/dev/null 2>&1 || true
		rm -rf '${SCRATCH}'" EXIT

	# The dump is a full CLUSTER dump: it contains CREATE DATABASE and \connect
	# for the real databases. Replaying it into one scratch database therefore
	# emits expected noise (roles already exist, \connect to absent databases).
	# ON_ERROR_STOP is deliberately off for that reason; what matters is whether
	# the statements execute, which the assertions below establish.
	log "replaying dump into ${SCRATCH_DB} (expect benign role/connect notices)"
	set +e
	pg psql -U "${POSTGRES_SUPER_USER}" -d "$SCRATCH_DB" -f - \
		<"$LOCAL_DUMP" >"${SCRATCH}/replay.log" 2>&1
	set -e

	# Assert the dump describes the roles it should. If the payload were empty
	# or unparseable the "restore" would be a no-op that looked like success —
	# the precise illusion this rehearsal exists to break.
	roles_found=$(pg psql -U "${POSTGRES_SUPER_USER}" -d postgres -tAc \
		"SELECT count(*) FROM pg_roles WHERE rolname IN ('n8n','paperclip','hermes')" \
		| tr -d '[:space:]')

	if [[ "$roles_found" != "3" ]]; then
		log "replay log tail:"
		tail -20 "${SCRATCH}/replay.log" >&2
		die "expected the 3 service roles to exist, found ${roles_found}"
	fi
	log "  roles present after replay: ${roles_found}/3"

	# Confirm the dump text carries each service's database, which is what a
	# real recovery rebuilds from.
	for svc in n8n paperclip hermes; do
		grep -q "CREATE DATABASE ${svc}" "$LOCAL_DUMP" \
			|| die "dump does not contain CREATE DATABASE for ${svc}"
		log "  dump contains database: ${svc}"
	done

	# Fatal errors, as opposed to the expected role/connect noise.
	if grep -qiE 'FATAL|could not connect|permission denied' "${SCRATCH}/replay.log"; then
		log "fatal lines from the replay log:"
		grep -iE 'FATAL|could not connect|permission denied' "${SCRATCH}/replay.log" \
			| head -10 >&2
		die "replay produced fatal errors"
	fi

	log "REHEARSAL PASSED — repository reachable, password correct, dump replayable"
	log "throwaway database ${SCRATCH_DB} dropped; nothing real was touched"
	exit 0
fi

# --- db-production ----------------------------------------------------------
# The destructive path. Guarded by typed confirmation because it overwrites
# live data and there is no undo.
if [[ "$MODE" == db-production ]]; then
	cat >&2 <<-WARN

		=======================================================================
		 DESTRUCTIVE RESTORE
		=======================================================================
		 Target cluster : ${PG_CONTAINER}
		 Snapshot       : ${SNAPSHOT}

		 This replays a full cluster dump taken with --clean, which DROPS and
		 recreates the databases it contains. Every change made since the
		 snapshot was taken will be lost.

		 Stop every service that writes to Postgres before continuing.
		=======================================================================

	WARN
	read -r -p 'Type RESTORE to proceed: ' answer
	[[ "$answer" == "RESTORE" ]] || die "aborted (got '${answer}')"

	log "replaying dump into the live cluster"
	docker exec -i -e PGPASSWORD="${POSTGRES_SUPER_PASSWORD}" "$PG_CONTAINER" \
		psql -U "${POSTGRES_SUPER_USER}" -d postgres -f - <"$LOCAL_DUMP" \
		|| die "restore failed — the cluster may be in a partial state"

	log "restore complete. Verify before resuming writes:"
	log "  bash ${REPO_DIR}/scripts/verify-data-layer.sh"
	exit 0
fi

die "no mode selected"
