terraform {
  required_version = ">= 1.8"

  # State lives in S3-compatible object storage. Values are supplied at init:
  #   tofu init -backend-config=backend.hcl   (gitignored; see README)
  # Bootstrapping chicken-and-egg: the state bucket is created once with a local
  # backend, then state is migrated (docs/runbooks/tofu-bootstrap.md).
  backend "s3" {
    key                         = "aevia/production.tfstate"
    region                      = "eu-central"
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
    use_path_style              = true
  }

  required_providers {
    hcloud     = { source = "hetznercloud/hcloud", version = "~> 1.48" }
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 5.0" }
    aws        = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}
