# ADR-0002: Applications run only in Docker

- **Status:** Accepted
- **Date:** 2026-07-28
- **Milestone:** M0

## Context

Servers rot when application dependencies are installed directly onto the host.
Python versions conflict, a `postgresql` apt package pins a major version, and
after two years nobody can say which of 400 installed packages are load-bearing.

## Decision

**No application is installed on the host. Everything runs in a container.**

The only software installed directly on Ubuntu:

- Docker CE + Compose plugin (the platform itself)
- `ufw`, `fail2ban`, `unattended-upgrades` (host security, must survive Docker)
- `git`, `curl`, `vim`, `htop`, `lazydocker` (operator tooling)

Anything else — PostgreSQL, Redis, Caddy, n8n, agents, MCP servers — is a
container defined in Compose. If something seems to need host installation, that
is a signal to re-examine, not an exception to grant.

## Alternatives considered

**Native install for databases.** Marginally better I/O, simpler backups via
`pg_dump` locally. Rejected: couples the Postgres major version to Ubuntu's
release cycle, which is precisely the trap that forces server rebuilds.

**Podman instead of Docker.** Rootless by default, no daemon, better security
posture on paper. Rejected: the surrounding ecosystem (Compose specifics, n8n
docs, GHCR tooling, most guides) assumes Docker. The security gain is real but
smaller than the friction, and it can be revisited without changing anything
else in this architecture.

## Trade-offs

**Gained:** every service's version is explicit and pinned (ADR-0011). Wiping a
service is `docker compose rm` plus a volume delete. The host stays boring.

**Given up:** a layer of indirection when debugging. Container networking is a
new failure mode. Docker itself must be kept current.

## Consequences

- Debugging happens via `docker compose logs`, `docker exec`, `lazydocker`.
- Persistent data lives in named volumes under `/opt/life-server/data/`, which
  is what M5 backs up.
- Anyone tempted to `apt install` an application should read this ADR first.

## Follow-up

- [ ] M2: install Docker via the `docker` role, with log rotation configured
- [ ] M2: verify no application listens on a host port
