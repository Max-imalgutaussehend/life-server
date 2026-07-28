# ADR-0010: Environment separation by prefix on one host

- **Status:** Accepted
- **Date:** 2026-07-28
- **Milestone:** M0 (decision), M2 (structure), M9 (dev stack deployed)

## Context

New agents and MCP servers need somewhere to be tested before they touch
production. A second server doubles cost and maintenance for a one-person
system. Some isolation is needed; full hardware isolation is not affordable.

## Decision

**Two stacks on one host, separated by an `ENV` prefix applied to every named
resource.**

```
/opt/life-server/       ENV=prod   main branch
/opt/life-server-dev/   ENV=dev    develop branch
```

| Resource | prod | dev |
|---|---|---|
| hostname | `n8n.maxrommel.de` | `n8n.dev.maxrommel.de` |
| container | `prod-n8n` | `dev-n8n` |
| network | `prod-net-data` | `dev-net-data` |
| volume | `prod-postgres-data` | `dev-postgres-data` |
| database | `prod` Postgres container | `dev` Postgres container |

Two derived variables express this everywhere:

- `ENV_PREFIX` — DNS infix: `""` for prod, `".dev"` for dev
- `ENV_PREFIX_NAME` — object prefix: `"prod-"` / `"dev-"`

**The structure is adopted in M2, when only prod exists.** Retrofitting prefixes
onto running containers, volumes and networks later means recreating all of
them; adopting the convention while there is nothing to migrate costs nothing.

## Alternatives considered

**A second Hetzner server.** True isolation. Rejected on cost and doubled
maintenance for a single operator. Remains available: because the playbook and
Compose files are environment-parameterised, standing one up later is running
the same code with `ENV=prod` on new hardware, not a redesign.

**Docker Compose profiles in one project.** Fewer directories. Rejected: shared
networks and volumes between profiles are easy to create by accident, which
defeats the isolation.

**No dev environment; test in production.** Honest about a one-person setup.
Rejected given the explicit goal of running autonomous agents — an agent with a
bug should not be able to touch production data.

## Trade-offs

**Gained:** dev containers cannot reach prod databases (different networks,
different credentials, ADR-0004). Testing a new agent is safe. The path to a
second host stays open.

**Given up — and this is the honest limit:** this is process-level isolation on
shared hardware. It does **not** protect against kernel panic, a full disk, an
OOM killer choosing a prod container, or a container escape. For "test an MCP
server before it goes live" it is sufficient. For "prod must survive anything
dev does" it is not.

**Resource cost:** the dev stack roughly doubles RAM usage. On 3.7 GB this is
the likely trigger for a CX32 upgrade at M9.

## Consequences

- No hostname is ever hardcoded; all derive from `SERVICE_NAME + ENV + DOMAIN`.
- Compose files use `${ENV_PREFIX_NAME}` for every `container_name`, network and
  volume.
- `scripts/setup-env.sh` derives both prefix variables from `ENV`.
- The dev stack is not deployed until M9 — the structure exists from M2 so that
  it can be, without migration.

## Follow-up

- [ ] M2: prefix all networks and volumes
- [ ] M4: verify a dev container cannot reach the prod database
- [ ] M9: deploy the dev stack; reassess RAM
