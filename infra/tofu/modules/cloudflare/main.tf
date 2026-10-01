terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "aevia" {
  account_id    = var.account_id
  name          = var.tunnel_name
  config_src    = "cloudflare"
  tunnel_secret = var.tunnel_secret
}

locals {
  hostnames = {
    for name, s in var.services :
    name => s.apex ? var.domain : "${name}.${var.domain}"
  }
}

# One wildcard-style rule set: every hostname goes to the in-cluster ingress,
# which routes by Host header. Routing logic stays in Kubernetes (ADR-0028).
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "aevia" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.aevia.id

  config = {
    ingress = concat(
      [for h in values(local.hostnames) : {
        hostname = h
        service  = var.ingress_service
      }],
      [{ service = "http_status:404" }]
    )
  }
}

resource "cloudflare_dns_record" "service" {
  for_each = local.hostnames

  zone_id = var.zone_id
  name    = each.value
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.aevia.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}
