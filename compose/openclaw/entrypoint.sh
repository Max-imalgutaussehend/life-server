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
#
# THE REPO MUST DESCRIBE EVERY CHANNEL IT WANTS
#   Re-seeding overwrites openclaw.json wholesale, so anything `openclaw
#   channels login` writes INTO that file is lost on the next start. That is
#   not hypothetical: the first successful WhatsApp pairing wrote an
#   `accounts` entry, the next restart re-seeded over it, and the gateway came
#   back reporting "no configured chat channels" while the session files sat
#   on disk, intact and unreferenced.
#
#   The session itself lives in /home/node/.openclaw/credentials and survives
#   fine. Only the CONFIG POINTER is lost — so channels.whatsapp.accounts is
#   declared in the repo copy, and a re-pair is not needed after a deploy.
#
# WHY openclaw.json LOOKS THE WAY IT DOES
#   JSON takes no comments and OpenClaw validates strictly (a "//" key is a
#   hard error), so the reasoning lives here.
#
#   channels.whatsapp.accounts + defaultAccount
#     Written by `channels login`; without it the gateway reports "no
#     configured chat channels" even with a valid, linked session on disk.
#
#   plugins.entries.whatsapp.enabled = true
#     WhatsApp is an EXTERNAL plugin. Without explicit trust the gateway logs
#     "installed without explicit trust" and auto-enables it per run "without
#     writing config" — so pairing works live and is gone after a restart.
#
#   plugins.allow = ["whatsapp"]
#     An empty allow list lets ANY discovered plugin auto-load. This container
#     runs model-chosen code; the set of loadable plugins is not left open.
#
#   dmPolicy=allowlist / allowFrom / groupPolicy=disabled
#     Only the operator's number reaches the agent, and group chats cannot.
#     The defaults (pairing/allowlist) are close, but this is the one surface
#     reachable from the public internet, so it is stated rather than inherited.
#
#   tools.profile=messaging + toolSearch.mode=directory
#     NOT a preference — a hard requirement of the subscription proxy. The full
#     36-tool catalog makes a ~76 KB request, and above ~54 KB the upstream
#     returns 400 "Third-party apps now draw from your extra usage", which
#     OpenClaw surfaces as a bogus "out of credits" error. Measured 2026-08-02:
#     15 tools/53,125 B passes, 16 tools/54,101 B fails. Keep the catalog
#     bounded or the agent stops answering.
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
