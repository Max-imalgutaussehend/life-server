# infra/tofu — OpenTofu owns Hetzner (server, firewall, volumes), Cloudflare (DNS, tunnel, Access) and backup storage. Not Kubernetes workloads. See ADR-0028.

## Usage

```
cd environments/production
cp backend.hcl.example backend.hcl        # gitignored
tofu init -backend-config=backend.hcl
tofu plan  -var-file=production.tfvars    # gitignored; secrets via SOPS
```

Nothing here is applied automatically. `plan` runs in CI; `apply` is manual
until phase 29 (see ../../docs/migration/R2-PLAN.md).
