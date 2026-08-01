#!/bin/sh
# =============================================================================
# entrypoint.sh — render CLIProxyAPI's config, then exec it. (M11, ADR-0020)
# =============================================================================
#
# WHY A RENDER STEP AT ALL
#   CLIProxyAPI reads api-keys from a YAML file, not from the environment. The
#   key is a secret, so it cannot live in the committed config. This substitutes
#   it at start into a file under /data, which is a volume — the repo copy stays
#   a template with a placeholder in it.
#
# WHY IT FAILS CLOSED
#   An unset PROXY_API_KEY would render an empty api-key, and an empty key means
#   anything on net-agent can spend the operator's subscription. That is the
#   exact prompt-injection scenario the sandbox exists to contain, so it is an
#   error, not a default.
# =============================================================================
set -eu

TEMPLATE=/etc/cliproxy/config.yaml
RENDERED=/data/config.yaml

if [ -z "${PROXY_API_KEY:-}" ]; then
	echo "error: PROXY_API_KEY is empty — refusing to start an unauthenticated proxy" >&2
	echo "       (anything on net-agent could otherwise spend the subscription)" >&2
	exit 1
fi

mkdir -p /data/auth

# sed with a non-slash delimiter: generated keys are base64 and contain '/'.
# The placeholder is a fixed sentinel, so there is nothing else to escape.
sed "s|__PROXY_API_KEY__|${PROXY_API_KEY}|" "$TEMPLATE" > "$RENDERED"
chmod 600 "$RENDERED"

# The credential the whole system depends on. Absent on a first run — the
# operator has to log in once, interactively — so this WARNS rather than
# failing: a proxy that is up but unauthenticated is diagnosable, whereas a
# container in a restart loop hides the reason it will not start.
#
# `ls` rather than a glob test: an unmatched glob in sh is passed through
# literally, so `[ -s /data/auth/*.json ]` would test a filename containing an
# asterisk and quietly report the wrong thing.
if ! ls /data/auth/*.json >/dev/null 2>&1; then
	# The container name, not $HOSTNAME: POSIX sh does not define HOSTNAME
	# (SC3028), so interpolating it here would print an empty name in the one
	# message whose whole job is to be copy-pasteable.
	echo "warning: no Claude credential in /data/auth — the proxy will answer but cannot serve models." >&2
	echo "         Run:  make proxy-login" >&2
fi

# /CLIProxyAPI/CLIProxyAPI, verified against the image — NOT /cli-proxy-api,
# which is what the package is called and what I first guessed. Flags are
# single-dash Go stdlib style (-config, not --config); `--config` is parsed as
# a positional argument and the config is silently ignored.
exec /CLIProxyAPI/CLIProxyAPI -config "$RENDERED" "$@"
