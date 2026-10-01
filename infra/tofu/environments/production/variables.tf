variable "hcloud_token" {
  type      = string
  sensitive = true
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

variable "cloudflare_account_id" {
  type = string
}

variable "cloudflare_zone_id" {
  type = string
}

variable "domain" {
  type = string
}

variable "tunnel_secret" {
  type      = string
  sensitive = true
}

variable "ssh_public_key" {
  type = string
}

variable "ssh_allowed_cidrs" {
  type    = list(string)
  default = []
}

variable "object_storage_endpoint" {
  description = "e.g. https://nbg1.your-objectstorage.com"
  type        = string
}

variable "object_storage_access_key" {
  type      = string
  sensitive = true
}

variable "object_storage_secret_key" {
  type      = string
  sensitive = true
}

variable "nodes" {
  type = map(object({
    role        = string
    server_type = string
    volume_gb   = optional(number, 0)
  }))
  default = {
    "01" = { role = "control", server_type = "cx32", volume_gb = 0 }
    # "01" = { role = "agent", server_type = "cx32" }  # phase 23
  }
}
