#!/usr/bin/env bash
# =============================================================================
# backup-pull.sh — copy the server's restic repository to this workstation.
# =============================================================================
#
# WHY THIS EXISTS
#   The server's repository at /srv/restic is on the same disk as the data it
#   protects, so it does not survive disk loss, host loss, or account loss —
#   the failures backups exist for (ADR-0009). This pulls the whole repository
#   to a machine that is different hardware, in a different building, on a
#   different provider's account. That closes the off-host requirement.
#
# WHY PULL AND NOT PUSH
#   A laptop is not always on. A server pushing to it on a 02:30 timer would
#   fail most nights, and a backup that routinely fails trains you to ignore
#   it — the exact "silently broken backup is worse than none" failure ADR-0009
#   warns about. Inverting the direction means the transfer happens when this
#   machine is awake, so a run either works or is genuinely worth reading.
#
# THE HONEST LIMITATION
#   The off-host copy is only as fresh as the last time you ran this. Between
#   pulls, only the server-side daily tier protects you. `--status` reports the
#   age of the local copy so the gap is visible rather than assumed.
#
# WHY rsync AND NOT `restic copy`
#   A restic repository is content-addressed and append-mostly, so rsync
#   transfers only new pack files and the result is a byte-identical repository
#   that this machine's own restic can open, check and restore from — without
#   needing the server at all. `restic copy` would re-encrypt into a second
#   repository with different IDs, which is slower and harder to reason about.
#
# USAGE
#   make backup-pull             # pull now
#   make backup-pull-status      # how old is the local copy?
#   ./scripts/backup-pull.sh --verify   # pull, then restic check locally
# =============================================================================
set -euo pipefail

SSH_KEY="${SSH_KEY:-$HOME/.ssh/life-server}"
SERVER="${SERVER:-deploy@62.238.4.64}"
REMOTE_REPO="${REMOTE_REPO:-/srv/restic}"
LOCAL_REPO="${LOCAL_REPO:-$HOME/life-server-backups/restic}"

MODE=pull
case "${1:-}" in
	--verify) MODE=verify ;;
	--status) MODE=status ;;
	"")       MODE=pull ;;
	*) echo "usage: $0 [--verify|--status]" >&2; exit 2 ;;
esac

log() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1"; }
die() { printf '%s  ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >&2; exit 1; }

# --- status -----------------------------------------------------------------
# Reports staleness. Deliberately loud past a week: the value of this copy
# decays with time since the last run, and that decay is invisible otherwise.
if [[ "$MODE" == status ]]; then
	if [[ ! -d "$LOCAL_REPO" ]]; then
		echo "No local copy at ${LOCAL_REPO}."
		echo "This machine holds NO off-host backup. Run: make backup-pull"
		exit 1
	fi

	stamp="${LOCAL_REPO}/.last-pull"
	if [[ ! -f "$stamp" ]]; then
		echo "Local copy exists but has no pull marker — age unknown."
		exit 1
	fi

	last=$(cat "$stamp")
	# BSD date (macOS) first, GNU date second, so this works on either.
	last_epoch=$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$last" +%s 2>/dev/null \
		|| date -d "$last" +%s 2>/dev/null || echo 0)
	now_epoch=$(date +%s)
	age_days=$(( (now_epoch - last_epoch) / 86400 ))

	echo "Local off-host copy : ${LOCAL_REPO}"
	echo "Size                : $(du -sh "$LOCAL_REPO" | cut -f1)"
	echo "Last pull           : ${last} (${age_days} days ago)"

	if [[ "$age_days" -ge 7 ]]; then
		echo
		echo "WARNING: the off-host copy is ${age_days} days old. Anything the"
		echo "WARNING: server has written since then exists in ONE place only."
		exit 1
	fi
	exit 0
fi

# --- pull -------------------------------------------------------------------
command -v rsync >/dev/null || die "rsync is not installed"

mkdir -p "$LOCAL_REPO"
# 0700: the repository is encrypted, but its structure and sizes are still
# metadata worth not exposing to other accounts on this machine.
chmod 700 "$(dirname "$LOCAL_REPO")" "$LOCAL_REPO"

log "pulling ${SERVER}:${REMOTE_REPO} -> ${LOCAL_REPO}"

# The repository is root-owned on the server, so the read runs under sudo.
# --rsync-path is how a non-root SSH login reads root-owned files without
# loosening permissions on the server.
#
# NOT using --delete: a repository damaged or truncated on the server must not
# propagate that damage into the only off-host copy. Extra local pack files are
# harmless — restic ignores unreferenced data — whereas silently deleted ones
# are unrecoverable.
rsync -az --info=stats1 \
	--rsync-path='sudo rsync' \
	-e "ssh -i $SSH_KEY -o BatchMode=yes" \
	"${SERVER}:${REMOTE_REPO}/" "${LOCAL_REPO}/" \
	|| die "rsync failed — the off-host copy was NOT updated"

date -u +%Y-%m-%dT%H:%M:%SZ >"${LOCAL_REPO}/.last-pull"

log "pull complete: $(du -sh "$LOCAL_REPO" | cut -f1)"

# --- verify -----------------------------------------------------------------
# Proves the pulled copy is a usable repository on THIS machine, independent of
# the server. Without this the pull is just bytes assumed to be good.
if [[ "$MODE" == verify ]]; then
	command -v restic >/dev/null \
		|| die "restic is not installed locally (brew install restic) — cannot verify"

	[[ -f .env ]] || die ".env not found; RESTIC_PASSWORD is needed to open the repository"
	# Only RESTIC_PASSWORD is taken from .env. RESTIC_REPOSITORY is overridden
	# to the LOCAL path — reading the server's value here would verify the
	# wrong repository and report success for a copy nobody checked.
	RESTIC_PASSWORD="$(grep -E '^RESTIC_PASSWORD=' .env | cut -d= -f2-)"
	[[ -n "$RESTIC_PASSWORD" ]] || die "RESTIC_PASSWORD is empty in .env"
	export RESTIC_PASSWORD
	export RESTIC_REPOSITORY="$LOCAL_REPO"

	log "verifying the local copy with this machine's restic"
	restic check || die "the local copy FAILED restic check — do not trust it"

	log "snapshots in the local copy:"
	restic snapshots --compact || die "cannot list snapshots in the local copy"

	log "VERIFIED — this machine holds an independently restorable backup"
fi
