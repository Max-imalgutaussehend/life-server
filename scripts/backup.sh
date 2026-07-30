#!/usr/bin/env bash
# =============================================================================
# backup.sh — take one restic snapshot of everything that cannot be rebuilt.
# =============================================================================
#
# WHAT IS BACKED UP, AND WHY EACH ITEM
#   1. pg_dumpall output   A file-level copy of a RUNNING Postgres is not
#                          crash-consistent — it can restore into a corrupt
#                          state. A logical dump is consistent by definition,
#                          so the database is dumped, never copied. (ADR-0009)
#   2. .env                NOT in Git (ADR-0006). Without it a total loss means
#                          regenerating every secret and losing every
#                          credential n8n has stored. The single easiest thing
#                          to forget and the most expensive to lose.
#   3. Docker volumes      Redis AOF/RDB, Caddy's data, and later app volumes.
#   4. The repo checkout   Cheap, and makes a bare-metal rebuild one restore
#                          rather than a clone plus a re-run of setup.
#
#   Postgres' DATA DIRECTORY is deliberately excluded — item 1 replaces it.
#   Backing up both would double the size and invite restoring the wrong one.
#
# WHY THIS RUNS ON THE HOST AND NOT IN A CONTAINER
#   It needs to read Docker volume contents and .env, and is driven by systemd.
#   A containerised restic would need the docker socket plus host mounts, which
#   is a larger attack surface than a host script run by a systemd timer.
#
# FAILURE BEHAVIOUR
#   Any failed step aborts with a non-zero exit. The systemd unit surfaces that
#   as a failed service, and M8 will turn it into an ntfy alert. A backup that
#   fails silently is worse than no backup, because it is trusted. (ADR-0009)
#
# USAGE
#   make backup                       # from the workstation
#   sudo /opt/life-server/scripts/backup.sh
#   sudo .../backup.sh --check        # also read-verify all pack data
# =============================================================================
set -euo pipefail

REPO_DIR="${REPO_DIR:-/opt/life-server}"
STAGING="${STAGING:-/var/lib/life-server-backup}"
RUN_CHECK=false
[[ "${1:-}" == "--check" ]] && RUN_CHECK=true

log() { printf '%s  %s\n' "$(date --iso-8601=seconds)" "$1"; }
die() { printf '%s  ERROR: %s\n' "$(date --iso-8601=seconds)" "$1" >&2; exit 1; }

# --- Configuration ----------------------------------------------------------
# RESTIC_PASSWORD and RESTIC_REPOSITORY come from .env. Exported so restic sees
# them in its environment rather than on a command line, where `ps` would
# expose them to every user on the host.
[[ -f "${REPO_DIR}/.env" ]] || die "${REPO_DIR}/.env not found"
set -a
# shellcheck disable=SC1091  # server-side path, not resolvable at lint time
. "${REPO_DIR}/.env"
set +a

[[ -n "${RESTIC_REPOSITORY:-}" ]] || die "RESTIC_REPOSITORY is not set in .env"
[[ -n "${RESTIC_PASSWORD:-}" ]]   || die "RESTIC_PASSWORD is not set in .env"

if [[ "$RESTIC_REPOSITORY" == "__SET_MANUALLY__" ]]; then
	die "RESTIC_REPOSITORY is still the placeholder. Set a real destination."
fi

# A local repository under the data it protects is not a backup. Refuse the
# clearly-wrong case outright rather than appearing to succeed.
case "$RESTIC_REPOSITORY" in
	/*)
		if [[ "$RESTIC_REPOSITORY" == "${REPO_DIR}"/* ]]; then
			die "RESTIC_REPOSITORY is inside ${REPO_DIR} — it would back up into itself"
		fi
		log "WARNING: local repository (${RESTIC_REPOSITORY})."
		log "WARNING: on the same disk as the data this does NOT survive disk or"
		log "WARNING: host loss. Move it off-host before storing real data (ADR-0009)."
		;;
esac

ENV_PREFIX_NAME="${ENV_PREFIX_NAME:-prod-}"
PG_CONTAINER="${PG_CONTAINER:-${ENV_PREFIX_NAME}postgres}"

# Retention. Generous because the data is small; the point is to survive
# "the corruption started three weeks ago and nobody noticed".
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
KEEP_MONTHLY="${KEEP_MONTHLY:-6}"

command -v restic >/dev/null || die "restic is not installed (run: make harden)"

# --- Staging ----------------------------------------------------------------
# 0700: the dump contains every table in every database. World-readable
# staging would hand it to any user on the host.
umask 077
mkdir -p "$STAGING"
chmod 700 "$STAGING"

# Always clear staging, on success or failure. Without this a crashed run
# leaves a plaintext database dump on disk indefinitely.
cleanup() {
	local rc=$?
	rm -rf "${STAGING:?}/dump" 2>/dev/null || true
	return $rc
}
trap cleanup EXIT

mkdir -p "${STAGING}/dump"

# --- 1. Postgres logical dump ----------------------------------------------
# pg_dumpall covers every database plus roles in one consistent operation
# (ADR-0009 follow-up). If Postgres is not running this aborts: a backup
# missing the database must never look like a success.
docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER" \
	|| die "${PG_CONTAINER} is not running — refusing to back up without the database"

log "dumping all databases from ${PG_CONTAINER}"
# --clean makes the dump restorable over an existing cluster.
if ! docker exec -e PGPASSWORD="${POSTGRES_SUPER_PASSWORD}" "$PG_CONTAINER" \
	pg_dumpall -U "${POSTGRES_SUPER_USER}" --clean \
	>"${STAGING}/dump/pg_dumpall.sql" 2>"${STAGING}/dump/pg_dumpall.err"; then
	log "pg_dumpall stderr:"
	cat "${STAGING}/dump/pg_dumpall.err" >&2
	die "pg_dumpall failed — aborting rather than storing a partial backup"
fi
rm -f "${STAGING}/dump/pg_dumpall.err"

# A dump that exists but is truncated is the failure mode these two catch.
size=$(stat -c%s "${STAGING}/dump/pg_dumpall.sql")
[[ "$size" -gt 1024 ]] || die "pg_dumpall output is only ${size} bytes — suspect"
grep -q 'PostgreSQL database cluster dump complete' "${STAGING}/dump/pg_dumpall.sql" \
	|| die "pg_dumpall output has no completion marker — the dump is truncated"
log "dump ok ($(numfmt --to=iec "$size"))"

# --- 2. Initialise the repository on first run ------------------------------
if ! restic cat config >/dev/null 2>&1; then
	log "repository not initialised — running restic init"
	restic init || die "restic init failed"
fi

# --- 3. Snapshot ------------------------------------------------------------
# Docker volumes are read from /var/lib/docker/volumes. Postgres' data dir is
# excluded because the dump above supersedes it.
log "creating snapshot"
restic backup \
	--tag life-server \
	--host life-server \
	--exclude "*/prod-postgres-data/*" \
	--exclude "*/dev-postgres-data/*" \
	--exclude '*.sock' \
	--exclude '*/__pycache__/*' \
	"${STAGING}/dump" \
	"${REPO_DIR}" \
	/var/lib/docker/volumes \
	|| die "restic backup failed"

# --- 4. Retention -----------------------------------------------------------
# --prune actually reclaims space; without it removed data lingers forever.
log "applying retention (${KEEP_DAILY}d/${KEEP_WEEKLY}w/${KEEP_MONTHLY}m)"
restic forget \
	--tag life-server \
	--keep-daily "$KEEP_DAILY" \
	--keep-weekly "$KEEP_WEEKLY" \
	--keep-monthly "$KEEP_MONTHLY" \
	--prune \
	|| die "restic forget/prune failed"

# --- 5. Integrity -----------------------------------------------------------
# Structural check every run. --read-data reads every pack and is slow, so it
# is opt-in (the weekly timer passes --check).
if $RUN_CHECK; then
	log "verifying repository (full read)"
	restic check --read-data || die "restic check FAILED — the repository is damaged"
else
	log "verifying repository (structure)"
	restic check || die "restic check FAILED — the repository is damaged"
fi

# --- 6. Prove the snapshot contains what matters ----------------------------
# A snapshot that exists but omits .env or the dump is the silent failure this
# milestone exists to prevent. Assert, do not assume.
#
# The listing is taken ONCE into a file rather than re-running `restic ls` per
# path. Two reasons, both learned the hard way here: piping `restic ls` into
# `grep -q` makes grep exit on first match, closing the pipe and killing restic
# with SIGPIPE mid-read — which left the repository lock in a state that made
# the NEXT check return nothing and report a false "snapshot is missing .env".
# One listing, many greps: no repeated locking, no SIGPIPE, no false alarm.
log "confirming critical paths are present in the newest snapshot"
if ! restic ls latest >"${STAGING}/dump/.snapshot-listing" 2>/dev/null; then
	die "could not list the snapshot just created"
fi

for want in "${STAGING}/dump/pg_dumpall.sql" "${REPO_DIR}/.env"; do
	grep -qxF "$want" "${STAGING}/dump/.snapshot-listing" \
		|| die "snapshot is missing ${want}"
	log "  present: ${want}"
done

log "backup complete"
restic snapshots --tag life-server --latest 3 --compact 2>/dev/null || true
