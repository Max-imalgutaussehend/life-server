variable "account_id" {
  type = string
}

variable "zone_id" {
  type = string
}

variable "domain" {
  description = "Apex domain, e.g. example.com"
  type        = string
}

variable "tunnel_name" {
  type    = string
  default = "aevia"
}

variable "tunnel_secret" {
  description = "Base64, >=32 bytes. Supply from SOPS, never commit."
  type        = string
  sensitive   = true
}

variable "ingress_service" {
  description = "In-cluster address cloudflared forwards everything to (the gateway/ingress Service)."
  type        = string
  default     = "http://ingress.ingress.svc.cluster.local:80"
}

variable "services" {
  description = "Catalog services to publish: name => {exposure, apex}. Rendered from catalog/services.yml by the caller."
  type = map(object({
    exposure = string
    apex     = optional(bool, false)
  }))
}
