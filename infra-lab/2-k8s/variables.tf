variable "project_id" { type = string }
variable "region" { type = string }

variable "state_bucket" {
  description = "GCS bucket holding Terraform state for all stages"
  type        = string
}
