# Runbook: OpenTofu state bootstrap

State lives in S3-compatible object storage (`backend "s3"` in
`infra/tofu/environments/production/versions.tf`). The bucket is created by the
`storage` module, which itself needs state: bootstrap once with a local backend.

**Needs:** Hetzner API token, Cloudflare API token, object-storage keys. Billable.

1. `cd infra/tofu/environments/production`
2. Temporarily comment out the `backend "s3"` block; `tofu init`.
3. `tofu apply -target=module.storage` with a `production.tfvars` (gitignored).
4. Copy `backend.hcl.example` to `backend.hcl`, fill in bucket/endpoint/keys.
5. Restore the backend block; `tofu init -backend-config=backend.hcl -migrate-state`.
6. `tofu plan -var-file=production.tfvars` must show only the not-yet-created resources.

**Rollback:** before step 5 delete the local `terraform.tfstate` and `tofu destroy -target=module.storage`.
After step 5 the state is in the bucket; download it with `tofu state pull` before any destroy.

**Verify:** `tofu state list` works from a fresh clone using only `backend.hcl`.
