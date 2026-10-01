terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.48"
    }
  }
}

resource "hcloud_ssh_key" "operator" {
  name       = "${var.name_prefix}-operator"
  public_key = var.ssh_public_key
}

# Ingress is Cloudflare Tunnel only (outbound connection), so no public
# 80/443. SSH and the API server are opt-in by CIDR.
resource "hcloud_firewall" "node" {
  name = "${var.name_prefix}-node"

  dynamic "rule" {
    for_each = length(var.ssh_allowed_cidrs) > 0 ? { ssh = "22", api = "6443" } : {}
    content {
      description = rule.key
      direction   = "in"
      protocol    = "tcp"
      port        = rule.value
      source_ips  = var.ssh_allowed_cidrs
    }
  }

  rule {
    description = "icmp"
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_network" "cluster" {
  name     = "${var.name_prefix}-net"
  ip_range = "10.42.0.0/16"
}

resource "hcloud_network_subnet" "nodes" {
  network_id   = hcloud_network.cluster.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = "10.42.1.0/24"
}

resource "hcloud_server" "node" {
  for_each = var.nodes

  name         = "${var.name_prefix}-${each.value.role}-${each.key}"
  server_type  = each.value.server_type
  image        = var.image
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.operator.id]
  firewall_ids = [hcloud_firewall.node.id]

  labels = {
    project = var.name_prefix
    role    = each.value.role
  }

  network {
    network_id = hcloud_network.cluster.id
  }

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    hostname = "${var.name_prefix}-${each.value.role}-${each.key}"
  })

  depends_on = [hcloud_network_subnet.nodes]

  lifecycle {
    # A changed image/user_data must never silently rebuild a node that holds data.
    ignore_changes = [image, user_data, ssh_keys]
  }
}

resource "hcloud_volume" "data" {
  for_each = { for k, n in var.nodes : k => n if n.volume_gb > 0 }

  name      = "${var.name_prefix}-${each.key}-data"
  size      = each.value.volume_gb
  location  = var.location
  format    = "ext4"
  server_id = hcloud_server.node[each.key].id

  lifecycle {
    prevent_destroy = true
  }
}
