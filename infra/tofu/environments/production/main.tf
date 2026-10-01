provider "hcloud" {
  token = var.hcloud_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "aws" {
  region                      = "eu-central"
  access_key                  = var.object_storage_access_key
  secret_key                  = var.object_storage_secret_key
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  s3_use_path_style           = true

  endpoints {
    s3 = var.object_storage_endpoint
  }
}

locals {
  catalog  = yamldecode(file("${path.root}/../../../../catalog/services.yml"))
  services = { for s in local.catalog.services : s.name => { exposure = s.exposure, apex = try(s.apex, false) } }
}

module "hetzner" {
  source = "../../modules/hetzner"

  name_prefix       = "aevia"
  ssh_public_key    = var.ssh_public_key
  ssh_allowed_cidrs = var.ssh_allowed_cidrs
  nodes             = var.nodes
}

module "cloudflare" {
  source = "../../modules/cloudflare"

  account_id    = var.cloudflare_account_id
  zone_id       = var.cloudflare_zone_id
  domain        = var.domain
  tunnel_secret = var.tunnel_secret
  services      = local.services
}

module "storage" {
  source = "../../modules/storage"
}
