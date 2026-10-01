# Aevia R2 migration plan

R1 is frozen at `release-1`. R2 is built on branch `r2` against a parallel VPS.
Each phase needs: ADR, test, rollback. Status: `todo` unless noted.

| # | Phase | Needs credentials |
|---|---|---|
| 01 | R1 audit + freeze (tag `release-1` pushed; CI green; restore rehearsal) | no |
| 02 | Aevia rebrand (docs/text first; GitHub repo rename last) | no |
| 03 | Service inventory → `catalog/services.yml` | no |
| 04 | Remove agent stack (Paperclip, Hermes, OpenClaw, CLIProxy) | no |
| 05 | R2 repo design + OpenTofu modules | no |
| 06 | Provision parallel R2 VPS | Hetzner, tofu state |
| 07 | k3s bootstrap | server SSH |
| 08 | Cilium (default-deny per namespace) | — |
| 09 | Argo CD | — |
| 10 | Secrets (SOPS + age) | age key |
| 11 | Ingress / Cloudflare | Cloudflare |
| 12 | PostgreSQL (logical restore from R1, verified) | — |
| 13 | Redis | — |
| 14 | Authentik | — |
| 15 | MinIO | — |
| 16 | NATS | — |
| 17–20 | n8n, Uptime Kuma, ntfy, earnings-alpha, regime-lens | — |
| 21 | CI/CD (Actions → GHCR → Argo CD) | GitHub |
| 22 | Herdr runtime | — |
| 23 | Dedicated agent node (taint `workload=agent`) | Hetzner |
| 24 | AI gateway | provider keys |
| 25 | Observability (OTel, Prometheus, Loki, Tempo, Grafana, Hubble) | — |
| 26 | Security hardening | — |
| 27 | Backup | — |
| 28 | Disaster-recovery test (destroy → tofu → k3s → Argo → restore) | all |
| 29 | Traffic cutover | Cloudflare |
| 30 | R1 decommission | Hetzner |

Phases 01–05 are repo-only. Phase 06 onward touches billable infrastructure.
