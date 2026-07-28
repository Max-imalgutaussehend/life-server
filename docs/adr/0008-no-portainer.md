# ADR-0008: No Portainer

- **Status:** Accepted
- **Date:** 2026-07-28
- **Milestone:** M0

## Context

Portainer was in the original service list. It provides a web UI for Docker:
container status, logs, shell access, stack deployment.

To do that it requires access to the Docker socket. Access to the Docker socket
is equivalent to root on the host — a container can be started with the host
filesystem mounted and privileges escalated trivially. Portainer is therefore a
root-equivalent web application.

## Decision

**Portainer is not installed.**

Operational needs are met by:

| Need | Tool |
|---|---|
| container status | `make status` / `docker ps` |
| logs | `make logs` / `docker compose logs` |
| interactive browsing | `lazydocker` over SSH |
| service health | Uptime Kuma (M8) |
| restart / redeploy | `make deploy` (M7) |

If it is genuinely wanted later, it goes behind Cloudflare Access with SSO —
never merely "behind the tunnel" — and that decision gets its own ADR.

## Alternatives considered

**Portainer behind Cloudflare Access.** Access provides real authentication at
the edge. Rejected for now on a different ground: the value of Portainer is
clicking buttons, and clicking buttons is configuration drift. It works against
the goal that the repository describes the system.

**Portainer bound to localhost, reached via SSH tunnel.** No public exposure.
Rejected: still root-equivalent, and if you already have SSH you already have
`lazydocker`, which needs no additional running service.

## Trade-offs

**Gained:** one less root-equivalent service, one less web session to hijack,
one less container to keep patched. Operations stay in Git-visible commands.

**Given up:** no graphical overview. Some tasks are more convenient in a UI,
particularly when unfamiliar with Docker CLI.

## Consequences

- `lazydocker` is installed by the `common` Ansible role as the interactive
  alternative.
- Any future proposal to add Portainer must supersede this ADR and specify
  Cloudflare Access with SSO.

## Follow-up

- [ ] M1: install `lazydocker` in the `common` role
- [ ] M8: Uptime Kuma covers the "is it up?" question a dashboard would answer
