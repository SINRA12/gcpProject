variable "project_id" { type = string }
variable "region" { type = string }

variable "my_ips" {
  description = "CIDRs allowed through Cloud Armor (your own IPs)"
  type        = list(string)
  default     = []
}

variable "enable_armor" {
  description = "Create the Cloud Armor policy and attach it to the backend service. Off by default because new projects often have a SECURITY_POLICIES quota of 0."
  type        = bool
  default     = false
}

variable "enable_cloudflare" {
  type    = bool
  default = false
}

variable "haproxy_count" {
  type    = number
  default = 2
}

variable "state_bucket" {
  description = "GCS bucket holding Terraform state for all stages"
  type        = string
}
