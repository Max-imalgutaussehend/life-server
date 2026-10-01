output "nodes" {
  description = "name => {role, public_ipv4, private_ip}"
  value = {
    for k, s in hcloud_server.node : k => {
      name        = s.name
      role        = var.nodes[k].role
      public_ipv4 = s.ipv4_address
      private_ip  = one(s.network).ip
    }
  }
}
