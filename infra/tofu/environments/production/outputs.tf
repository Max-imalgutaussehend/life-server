output "nodes" {
  value = module.hetzner.nodes
}

output "tunnel_id" {
  value = module.cloudflare.tunnel_id
}

output "hostnames" {
  value = module.cloudflare.hostnames
}
