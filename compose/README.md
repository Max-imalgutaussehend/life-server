# compose/

Docker Compose stacks. Everything above the host baseline runs here
([ADR-0002](../docs/adr/0002-docker-only.md)).

## Layout

| Path | |
|---|---|
| `generated/` | **Machine-written. Never edit.** Produced from `services.yml`. |
| `docker-compose.prod.yml` | Production stack (M2+) |
| `docker-compose.dev.yml` | Development stack (M9) |

## Conventions

- **No `ports:` for web services.** Traffic arrives via the tunnel, not a host
  port ([ADR-0003](../docs/adr/0003-cloudflare-tunnel-terminates-tls.md)).
- **Pinned versions only**, never `:latest`
  ([ADR-0011](../docs/adr/0011-pinned-image-versions.md)). Pre-commit enforces.
- **Prefix every named resource** with `${ENV_PREFIX_NAME}` — containers,
  networks, volumes ([ADR-0010](../docs/adr/0010-env-prefix-dev-prod.md)).
- **Join only the networks a service needs**
  ([ADR-0004](../docs/adr/0004-segmented-docker-networks.md)).

## Current state

Only `generated/` exists. Stacks are written in M2.
