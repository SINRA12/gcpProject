variable "project_id" { type = string }
variable "region" { type = string }

variable "state_bucket" {
  description = "GCS bucket holding Terraform state for all stages"
  type        = string
}

variable "chart_version" {
  description = "kube-prometheus-stack Helm chart version"
  type        = string
  default     = "92.17.0"
}

variable "grafana_root_url" {
  description = "Public URL Grafana is served at. Empty means http://<load balancer IP>/grafana/"
  type        = string
  default     = ""
}
