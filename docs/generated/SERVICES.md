<!--
  GENERATED FILE — DO NOT EDIT
  Source:    services.yml
  Generator: generator/render.py
  Regenerate: make generate
-->

# Service Inventory

Generated from [`services.yml`](../../services.yml). Do not edit by hand —
add or change a service there and run `make generate`.

## Deployed

| Service | Hostname (prod) | Hostname (dev) | Port | Access | Networks | Health |
|---|---|---|---|---|---|---|
| `n8n` | `n8n.$DOMAIN` | `n8n.dev.$DOMAIN` | 5678 | private | apps, data | `/healthz` |
| `paperclip` | `paperclip.$DOMAIN` | `paperclip.dev.$DOMAIN` | 3100 | private | apps, data | `/` |
| `status` | `status.$DOMAIN` | `status.dev.$DOMAIN` | 3001 | private | apps | `/` |
| `ntfy` | `ntfy.$DOMAIN` | `ntfy.dev.$DOMAIN` | 80 | private | apps | `/` |

## Declared, not yet deployed

_None._

## How hostnames are derived

No hostname is written by hand anywhere in this repository. Each is composed
at runtime from three values:

```
<service name> + <env infix> + <domain>

prod:  ENV_PREFIX=""      ->  n8n.maxrommel.de
dev:   ENV_PREFIX=".dev"  ->  n8n.dev.maxrommel.de
```

`DOMAIN` and `ENV` live in `.env`; `ENV_PREFIX` is derived from `ENV` by
`scripts/setup-env.sh`. Because `*.maxrommel.de` is a Cloudflare wildcard
record, a new service needs no DNS change — only a tunnel ingress rule, which
this generator produces.

## Access control

`access: private` means the hostname sits behind a **Cloudflare Access**
policy: authentication happens at Cloudflare's edge, before traffic reaches
the server. A service's own login (n8n's, for example) is then a second layer,
not the only one.

> **Manual verification required.** Access policies are configured in the
> Cloudflare Zero Trust dashboard and cannot be expressed in the tunnel config.
> This table is the intended state; the dashboard is the actual state. Audit
> them against each other whenever a service is added — see `docs/milestones/M3.md`.

## Network segmentation

| Network | Purpose | Who joins |
|---|---|---|
| `edge` | Tunnel ↔ reverse proxy | `cloudflared`, `caddy` |
| `apps` | Application containers | `caddy` + every app |
| `data` | Databases | `postgres`, `redis`, and only apps that need them |

A container reaches PostgreSQL only if it is explicitly placed on `data`.
This is what keeps a future MCP server or agent from touching the database
by default. See ADR-0004.
