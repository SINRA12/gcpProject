output "project_id" { value = var.project_id }
output "region" { value = var.region }
output "subnet_self_link" { value = google_compute_subnetwork.subnet.self_link }

output "clusters" {
  value = {
    for k, c in google_container_cluster.cluster : k => {
      endpoint = c.endpoint
      ca_cert  = c.master_auth[0].cluster_ca_certificate
    }
  }
}

output "ingress_ips" {
  value = { for k, a in google_compute_address.ingress : k => a.address }
}

output "lb_ip" { value = google_compute_global_address.lb.address }
output "lb_ip_id" { value = google_compute_global_address.lb.id }
