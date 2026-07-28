# generator/

Renders configuration from [`services.yml`](../services.yml).
See [ADR-0014](../docs/adr/0014-service-registry.md).

## What it produces

| Template | Output |
|---|---|
| `Caddyfile.j2` | `compose/generated/caddy/Caddyfile` |
| `cloudflared-config.yml.j2` | `compose/generated/cloudflared/config.yml` |
| `services.env.j2` | `compose/generated/services.env` |
| `SERVICES.md.j2` | `docs/generated/SERVICES.md` |

## Usage

```bash
make generate   # write
make check      # exit 1 if output is stale
```

## Why the output is committed

A generator you must run to know what is deployed is a black box. Committing
the output means the real Caddy config is readable without running Python,
`git diff` shows what a registry change did, and the server needs no Python.

Pre-commit runs `--check`, so stale output cannot be committed.

## Adding a new output

1. Write a template in `templates/`.
2. Add one line to `OUTPUTS` in `render.py`.
3. `make generate`.

## Design constraint

Deliberately boring: plain Python and Jinja2, no framework, no plugins, no
dynamic imports. This must be readable in one sitting three years from now.
`StrictUndefined` is on — a typo'd variable is an error, not an empty string.
