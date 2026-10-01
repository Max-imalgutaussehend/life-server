# Aevia

Personal platform on Hetzner: OpenTofu for infrastructure, k3s for runtime,
Argo CD for desired state, Cilium for network isolation, Cloudflare for the edge.

> **Status: R2 in progress (branch `r2`).** R1, the single-VPS Docker/Ansible
> implementation (formerly "life-server"), is frozen at tag `release-1` and keeps
> serving until the traffic cutover. Its README is [docs/r1/README.md](docs/r1/README.md).

## Layout

| Path | Purpose |
|---|---|
| `infra/tofu/` | OpenTofu: Hetzner server/firewall/volumes, Cloudflare DNS/tunnel, backup storage |
| `catalog/services.yml` | Service catalog: exposure, ports, dependencies, persistence |
| `docs/adr/` | Architecture decisions. [ADR-0028](docs/adr/0028-aevia-r2-kubernetes-platform.md) defines R2 |
| `docs/migration/R2-PLAN.md` | Phase plan, 01–30 |
| `ansible/`, `compose/`, `generator/` | R1 implementation, retired at cutover |

## Principles

1. R1 stays untouched until cutover; R2 is built on a parallel VPS.
2. Every phase ships with an ADR, a verification test and a rollback.
3. Nothing billable or outward-facing happens without explicit approval.
4. Agents cannot reach data services: Cilium default-deny plus an allow-list.

## Working with the tofu code

See [infra/tofu/README.md](infra/tofu/README.md). `tofu validate` runs without credentials:

```
cd infra/tofu/environments/production
tofu init -backend=false && tofu validate
```
