#!/usr/bin/env bash
# =============================================================================
# deploy.sh — sync this repo to the server and bring the stack up.
# =============================================================================
#
# WHY RSYNC AND NOT `git pull` ON THE SERVER
#   During M2-M6 the repo has no remote yet. rsync keeps the server in step
#   with your working copy without requiring GitHub. From M7 this is replaced
#   by a pull-based flow (ADR-0007), which is why the mechanism lives in one
#   script rather than being typed by hand.
#
# WHAT IS SYNCED
#   Everything Git tracks, plus .env — which is deliberately NOT in Git
#   (ADR-0006) but IS required to run. .git/ itself is excluded; the server
#   does not need history.
#
# SAFETY
#   --delete removes files on the server that no longer exist locally, so the
#   server cannot accumulate orphaned config. It is scoped to /opt/life-server,
#   never the whole filesystem.
#
# USAGE
#   make deploy-stack          # sync + up
#   ./scripts/deploy.sh --sync-only
# =============================================================================

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/life-server}"
SERVER="${SERVER:-deploy@62.238.4.64}"
REMOTE_DIR="/opt/life-server"
SYNC_ONLY=false

[[ "${1:-}" == "--sync-only" ]] && SYNC_ONLY=true

[[ -f "$REPO/.env" ]] || { echo "error: .env missing. Run: make setup" >&2; exit 1; }

echo "==> syncing $REPO -> $SERVER:$REMOTE_DIR"
rsync -az --delete \
	-e "ssh -i $SSH_KEY -o BatchMode=yes" \
	--exclude '.git/' \
	--exclude '__pycache__/' \
	--exclude '.DS_Store' \
	"$REPO/" "$SERVER:$REMOTE_DIR/"

# .env carries secrets and must not be readable by other users on the host.
ssh -i "$SSH_KEY" -o BatchMode=yes "$SERVER" "chmod 600 $REMOTE_DIR/.env"

if $SYNC_ONLY; then
	echo "==> sync complete (--sync-only)"
	exit 0
fi

echo "==> starting stack"
# --env-file twice: .env holds secrets, services.env holds generated hostnames
# and ports (ADR-0014). Compose merges them; later files win.
ssh -i "$SSH_KEY" -o BatchMode=yes "$SERVER" "
	set -euo pipefail
	cd $REMOTE_DIR
	docker compose \
		--env-file .env \
		--env-file compose/generated/services.env \
		-f compose/docker-compose.prod.yml \
		up -d --remove-orphans
"

echo "==> container status"
ssh -i "$SSH_KEY" -o BatchMode=yes "$SERVER" \
	"docker ps --format 'table {{.Names}}\t{{.Status}}'"
