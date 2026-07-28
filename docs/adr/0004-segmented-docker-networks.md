# ADR-0004: Three segmented Docker networks, not one

- **Status:** Accepted
- **Date:** 2026-07-28
- **Milestone:** M0 (decision), M2 (implementation)

## Context

The default Docker approach is one bridge network per Compose project, with
every container able to reach every other. On a host that will run autonomous
AI agents and third-party MCP servers, that means any such container can open
a socket to PostgreSQL and Redis by default.

Least privilege was an explicit requirement. One flat network contradicts it.

## Decision

**Three networks, joined explicitly per service.**

| Network | Purpose | Members |
|---|---|---|
| `edge` | tunnel ↔ proxy | `cloudflared`, `caddy` |
| `apps` | proxy ↔ applications | `caddy`, every app |
| `data` | applications ↔ databases | `postgres`, `redis`, and only apps that need them |

Rules:

- `postgres` and `redis` join **only** `data`. They are unreachable from `edge`.
- An application joins `data` only if it actually uses a database. An MCP server
  that does not need Postgres cannot reach Postgres.
- `cloudflared` never joins `apps` or `data` — it only talks to Caddy.
- All three networks are `internal: false` only where egress is required;
  `data` is `internal: true` (no outbound internet from the database network).

Network names carry the environment prefix (ADR-0010): `prod-net-data`,
`dev-net-data`. A dev container therefore cannot reach a prod database even by
name.

## Alternatives considered

**One network.** Simplest, zero config. Rejected: gives every present and
future container database access by default. Wrong default for an agent host.

**One network per service pair.** Maximum isolation. Rejected: the Compose file
becomes unreadable, and the marginal security gain over three tiers is small on
a single host.

**Docker's built-in `--icc=false`.** Blocks inter-container communication
globally, then requires explicit links. Rejected: a blunt, poorly-documented
flag that fights the Compose model; the three-network split expresses the same
intent legibly.

## Trade-offs

**Gained:** a compromised or misbehaving app container cannot reach the database
unless it was explicitly granted access. Adding an agent does not silently widen
the blast radius.

**Given up:** each new service needs a deliberate decision about which networks
it joins. This is the point, but it is friction.

**Not gained:** this is network-level isolation on one host. It does not defend
against a container escape to the host, or a compromised Caddy. It reduces
lateral movement, it does not eliminate it.

## Consequences

- `services.yml` has a required `networks:` field, validated by the generator
  against exactly `{edge, apps, data}`.
- A service requesting an unknown network fails generation with an error
  naming this ADR.
- `data` being `internal: true` means database containers cannot pull updates
  from the internet — image updates happen via the host's Docker daemon, which
  is correct.

## Follow-up

- [ ] M2: create the three networks with env prefixes
- [ ] M4: verify from an `apps`-only container that `postgres` is unreachable
- [ ] M9: confirm agent containers are not on `data` unless required
