#!/bin/sh
# =============================================================================
# entrypoint.sh — seed OmniRoute's config, then start the router. (M13)
# =============================================================================
#
# WHY THIS EXISTS
#   Same split as OpenClaw's entrypoint, for the same reason: OmniRoute owns
#   its data directory. It writes a SQLite database, an encrypted credential
#   store and lock files beside its config, so the directory cannot be a
#   read-only bind — but the CONFIG CONTENT must still come from Git, or the
#   routing behaviour of every agent turn lives only on a volume nobody can
#   review.
#
#   Repo is authoritative for content. Volume owns the directory.
#
# WHAT IS DELIBERATELY NOT TOUCHED
#   The SQLite database and anything else the router writes. Provider API keys
#   are stored there encrypted and exist nowhere else — re-seeding them away
#   would mean re-entering every key by hand.
#
# WHY THE CONFIG IS DECLARED AND NOT CLICKED
#   Upstream's intended workflow is the web dashboard: add providers by hand,
#   state lands in SQLite. That dashboard is the single largest memory cost in
#   this image (a Next.js app) and is switched off in compose — so config is
#   declared as a file instead. This is ADR-0014's principle applied by hand,
#   since this service is not in the generated registry.
# =============================================================================
set -eu

SEED=/seed/omniroute.json
CONFIG="${OMNIROUTE_CONFIG_PATH:-/data/omniroute.json}"

if [ ! -f "$SEED" ]; then
	echo "error: $SEED is missing — the compose mount is wrong" >&2
	exit 1
fi

# Copy CONTENT, not the file: `cp -p` would carry the read-only bind's
# permissions across and make the config unwritable, which is the exact
# problem this script exists to avoid.
if ! cat "$SEED" > "$CONFIG"; then
	echo "error: could not write $CONFIG — is /data writable?" >&2
	exit 1
fi

echo "omniroute: config seeded from repo -> $CONFIG"

# ⚠️ FIRST DEPLOY MUST CONFIRM THIS LINE IS TRUE.
# The OMNIROUTE_*_ENABLED vars in compose are unverified upstream names, and an
# unrecognised env var is ignored silently rather than rejected. If the
# dashboard is still served on :20128/dashboard after this starts, the trimming
# did not take effect and the memory limit will be hit instead.
echo "omniroute: dashboard=${OMNIROUTE_DASHBOARD_ENABLED:-unset} memory=${OMNIROUTE_MEMORY_ENABLED:-unset} stealth=${OMNIROUTE_STEALTH_ENABLED:-unset}"

exec omniroute
