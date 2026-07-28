#!/usr/bin/env bash
# =============================================================================
# setup-env.sh — create or repair .env from env.example  (ADR-0006)
# =============================================================================
#
# WHY THIS EXISTS
#   .env holds real passwords and is gitignored, so nothing in Git records
#   which variables exist or what they should be. Hand-maintained .env files
#   drift: a variable gets added during a late-night fix, never documented,
#   and two years later nobody knows if it is still needed. That drift is also
#   exactly what makes migrating to SOPS (M7) expensive.
#
#   So: env.example is the committed contract, this script is the only thing
#   that writes .env, and `make check-env` proves the two still agree.
#
# BEHAVIOUR
#   - .env missing      -> created from env.example, secrets generated
#   - .env exists       -> untouched values kept; only MISSING keys are added
#   - __GENERATE__      -> replaced with a random 40-char secret
#   - __SET_MANUALLY__  -> left as-is and reported; you must fill these in
#
#   Re-running is safe. It never overwrites a value you already have — losing
#   N8N_ENCRYPTION_KEY would make every credential n8n stores unreadable.
#
# USAGE
#   ./scripts/setup-env.sh          # create/repair .env
#   ./scripts/setup-env.sh --check  # report drift, write nothing (exit 1)
# =============================================================================

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE="$REPO/env.example"
ENV_FILE="$REPO/.env"
CHECK_ONLY=false

[[ "${1:-}" == "--check" ]] && CHECK_ONLY=true

[[ -f "$EXAMPLE" ]] || { echo "error: $EXAMPLE not found" >&2; exit 2; }

# 40 random alphanumeric chars. Deliberately excludes punctuation, which
# breaks unquoted shell expansion, YAML and connection URLs in subtle ways.
gen_secret() {
	LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40
}

# Keys declared in env.example, ignoring comments and blanks.
declared_keys() {
	grep -E '^[A-Z][A-Z0-9_]*=' "$EXAMPLE" | cut -d= -f1
}

existing_keys() {
	if [[ -f "$ENV_FILE" ]]; then
		grep -E '^[A-Z][A-Z0-9_]*=' "$ENV_FILE" | cut -d= -f1
	fi
}

# ── check mode: report drift in both directions ─────────────────────────────
if $CHECK_ONLY; then
	if [[ ! -f "$ENV_FILE" ]]; then
		echo "MISSING: .env does not exist. Run: make setup" >&2
		exit 1
	fi
	missing=$(comm -23 <(declared_keys | sort) <(existing_keys | sort) || true)
	extra=$(comm -13 <(declared_keys | sort) <(existing_keys | sort) || true)
	unset_vals=$(grep -E '^[A-Z][A-Z0-9_]*=(__GENERATE__|__SET_MANUALLY__)$' "$ENV_FILE" | cut -d= -f1 || true)

	rc=0
	if [[ -n "$missing" ]]; then
		echo "MISSING from .env (declared in env.example):" >&2
		echo "$missing" | sed 's/^/  /' >&2
		rc=1
	fi
	if [[ -n "$extra" ]]; then
		# Not fatal in itself, but undocumented — the exact drift this script exists
		# to prevent. Add it to env.example so the contract stays complete.
		echo "UNDOCUMENTED in .env (not in env.example) — add it to env.example:" >&2
		echo "$extra" | sed 's/^/  /' >&2
		rc=1
	fi
	if [[ -n "$unset_vals" ]]; then
		echo "PLACEHOLDER still unset in .env:" >&2
		echo "$unset_vals" | sed 's/^/  /' >&2
		rc=1
	fi
	[[ $rc -eq 0 ]] && echo "OK — .env matches env.example, no placeholders left"
	exit $rc
fi

# ── write mode ──────────────────────────────────────────────────────────────
created=false
if [[ ! -f "$ENV_FILE" ]]; then
	cp "$EXAMPLE" "$ENV_FILE"
	created=true
	echo "created .env from env.example"
else
	echo ".env exists — adding only missing keys, existing values untouched"
	while read -r key; do
		[[ -z "$key" ]] && continue
		if ! grep -qE "^${key}=" "$ENV_FILE"; then
			line=$(grep -E "^${key}=" "$EXAMPLE")
			printf '\n# added by setup-env.sh (was missing)\n%s\n' "$line" >> "$ENV_FILE"
			echo "  + $key"
		fi
	done < <(declared_keys)
fi

# Replace every __GENERATE__ placeholder with a fresh secret.
#
# NOTE ON `|| true` BELOW: this script runs under `set -e`. A `grep` that
# finds nothing exits 1, which would abort the whole script mid-loop — so
# every conditional grep here is explicitly neutralised. This bit the first
# version: secrets were silently never generated AND the chmod below was
# never reached, leaving a world-readable .env full of placeholders.
generated=0
while read -r key; do
	[[ -z "$key" ]] && continue
	if grep -qE "^${key}=__GENERATE__$" "$ENV_FILE" 2>/dev/null; then
		secret="$(gen_secret)"
		# awk + temp file rather than sed -i: the -i flag differs between
		# GNU and BSD/macOS, and this script runs on both.
		awk -v k="$key" -v v="$secret" \
			'$0 == k"=__GENERATE__" { print k"="v; next } { print }' \
			"$ENV_FILE" > "$ENV_FILE.tmp" && mv "$ENV_FILE.tmp" "$ENV_FILE"
		generated=$((generated + 1))
	fi
done < <(declared_keys) || true

if [[ $generated -gt 0 ]]; then
	echo "generated $generated secret(s)"
fi

# .env must never be world- or group-readable: database passwords and the
# n8n encryption key live here.
chmod 600 "$ENV_FILE"

manual=$(grep -E '^[A-Z][A-Z0-9_]*=__SET_MANUALLY__$' "$ENV_FILE" | cut -d= -f1 || true)
if [[ -n "$manual" ]]; then
	echo
	echo "ACTION REQUIRED — these need real values before the relevant milestone:"
	echo "$manual" | sed 's/^/  /'
fi

if $created; then
	echo
	echo "IMPORTANT: .env is NOT in Git (ADR-0006). Until SOPS lands in M7 it is"
	echo "the one part of this system that cannot be restored from the repo."
	echo "Copy RESTIC_PASSWORD and N8N_ENCRYPTION_KEY into your password manager."
fi
