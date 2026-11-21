variable "domain" { type = string }
variable "cloudflare_zone_id" { type = string }
variable "record_name" {
  type    = string
  default = "lab"
}

variable "state_bucket" {
  description = "GCS bucket holding Terraform state for all stages"
  type        = string
}
