# ADR-0028: Aevia R2 — transform life-server into a Kubernetes platform

- **Status:** Accepted (2026-10-01)
- **Date:** 2026-10-01
- **Milestone:** R2-P0
- **Supersedes:** ADR-0001, 0002, 0003, 0004, 0007, 0019, 0020, 0021, 0023

## Context

R1 (`release-1`, commit 3d3f90e) is a single Hetzner VPS: Ansible owns the host,
Docker Compose owns applications, `services.yml` owns external routing.
R2 ("Aevia") should be a reproducible personal platform with IaC, GitOps,
isolated agent compute, a shared identity/data layer, observability and a
tested disaster-recovery path.

## Decision

Responsibilities move, files are not ported one-to-one:

| Concern | R1 | R2 |
|---|---|---|
| Infrastructure | Ansible + manual | OpenTofu |
| Runtime | Docker Compose | k3s |
| Desired state | `make deploy` | Argo CD |
| Build | scripts | GitHub Actions + GHCR |
| Workload networking | Docker networks | Cilium NetworkPolicies |
| Edge | Cloudflare + Caddy | Cloudflare + cloudflared + Gateway/Ingress |

1. R1 stays frozen at tag `release-1` as the reference implementation.
2. R2 is built on a **new, parallel VPS**, never in place on the R1 host.
3. The agent stack (Paperclip, Hermes, OpenClaw, CLIProxy) is removed; its
   security idea (agents cannot reach Postgres/Redis/n8n) is kept as Cilium
   default-deny plus an explicit allow-list, with automated tests.
4. `services.yml` becomes `catalog/services.yml`, extended with deployment
   fields (replicas, resources, persistence, ingress, auth, network policy).
5. Every phase ships with an ADR, a verification test and a rollback.

## Consequences

- R1 keeps serving until the traffic cutover; failure of R2 costs only time.
- Two servers are billed during the migration.
- Caddy and the Compose generator are retired after cutover.
- Phases 6+ need credentials (Hetzner, Cloudflare, age key, tofu state store)
  and an explicit go-ahead per step.
