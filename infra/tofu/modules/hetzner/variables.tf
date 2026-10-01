variable "name_prefix" {
  description = "Prefix for all resource names, e.g. aevia"
  type        = string
}

variable "location" {
  description = "Hetzner location (nbg1, fsn1, hel1, ...)"
  type        = string
  default     = "nbg1"
}

variable "ssh_public_key" {
  description = "Operator public key installed on every node"
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to reach SSH (22) and the Kubernetes API (6443). Empty = nobody; use Cloudflare Access/Tailscale instead."
  type        = list(string)
  default     = []
}

variable "nodes" {
  description = "Cluster nodes. role=control runs platform workloads; role=agent is tainted workload=agent:NoSchedule by the k3s bootstrap."
  type = map(object({
    role        = string
    server_type = string
    volume_gb   = optional(number, 0)
  }))

  validation {
    condition     = alltrue([for n in values(var.nodes) : contains(["control", "agent"], n.role)])
    error_message = "node role must be control or agent."
  }
}

variable "image" {
  type    = string
  default = "ubuntu-24.04"
}
