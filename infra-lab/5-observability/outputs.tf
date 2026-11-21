output "grafana_url" { value = local.grafana_root_url }
output "grafana_user" { value = "admin" }

output "grafana_admin_password" {
  value     = random_password.grafana.result
  sensitive = true
}

output "payment_prometheus_url" {
  value = "http://${google_compute_address.payment_prometheus.address}:9090"
}
