variable "project_id" { type = string }
variable "region" { type = string }
variable "zone" { type = string }

variable "node_machine_type" {
  description = "Machine type of the GKE nodes. e2-standard-2 fits the monitoring stack; e2-medium is cheaper but runs out of CPU once Prometheus and Grafana are installed."
  type        = string
  default     = "e2-standard-2"
}
