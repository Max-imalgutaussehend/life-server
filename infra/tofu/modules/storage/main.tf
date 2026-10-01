terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "buckets" {
  description = "S3-compatible buckets (Hetzner Object Storage). Provider endpoint is configured by the caller."
  type        = set(string)
  default     = ["aevia-backups", "aevia-artifacts", "aevia-tofu-state"]
}

resource "aws_s3_bucket" "this" {
  for_each = var.buckets
  bucket   = each.value
}

resource "aws_s3_bucket_versioning" "this" {
  for_each = var.buckets
  bucket   = aws_s3_bucket.this[each.value].id

  versioning_configuration {
    status = "Enabled"
  }
}

output "buckets" {
  value = [for b in aws_s3_bucket.this : b.bucket]
}
