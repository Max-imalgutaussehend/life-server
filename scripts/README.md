# scripts/

Operational scripts. Each is invoked through a `make` target rather than
directly, so the correct arguments are recorded in one place.

| Script | Make target | Purpose |
|---|---|---|
| `setup-env.sh` | `make setup` / `make check-env` | Create or repair `.env` from `env.example` |

## Conventions

- `set -euo pipefail` at the top of every script.
- A `--check` mode that reports without writing, wherever it makes sense.
- Idempotent: running twice must be safe. `setup-env.sh` in particular must
  never overwrite an existing secret — losing `N8N_ENCRYPTION_KEY` would make
  every credential n8n stores unreadable.
- Comment *why*, not *what*.
