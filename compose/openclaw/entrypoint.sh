#!/bin/sh
# =============================================================================
# entrypoint.sh — seed OpenClaw's config, then start the gateway. (M11)
# =============================================================================
#
# WHY THIS EXISTS
#   OpenClaw treats /config as its own writable directory: it installs plugins
#   into extensions/ and takes a .lock file beside the config while doing so.
#   Mounting the repo's openclaw.json there read-only breaks both, and the
#   WhatsApp channel is itself a plugin — so a read-only config means no
#   WhatsApp.
#
#   The repo therefore stays authoritative for CONTENT and the volume owns the
#   DIRECTORY. This copies the former into the latter on every start, so a
#   config change in Git still lands on the next deploy and nothing drifts
#   silently.
#
# WHAT IS DELIBERATELY NOT TOUCHED
#   /config/extensions. Plugins are installed once and must survive restarts;
#   re-seeding them would destroy the WhatsApp pairing that depends on them.
# =============================================================================
set -eu

SEED=/seed/openclaw.json
CONFIG=/config/openclaw.json

if [ ! -f "$SEED" ]; then
	echo "error: $SEED is missing — the compose mount is wrong" >&2
	exit 1
fi

mkdir -p /config/extensions

# Copy CONTENT, not the file: `cp -p` would carry the read-only bind's
# permissions across and reintroduce the exact problem this exists to solve.
if ! cat "$SEED" > "$CONFIG"; then
	echo "error: could not write $CONFIG — is /config writable?" >&2
	exit 1
fi

echo "openclaw: config seeded from repo"
exec openclaw gateway run
