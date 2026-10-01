output "tunnel_id" {
  value = cloudflare_zero_trust_tunnel_cloudflared.aevia.id
}

output "hostnames" {
  value = local.hostnames
}

# Private services additionally need a Cloudflare Access application or the
# in-cluster Authentik layer (phase 14). Tracked as a blocker, not done here.
output "private_services" {
  value = [for n, s in var.services : n if s.exposure == "private"]
}
