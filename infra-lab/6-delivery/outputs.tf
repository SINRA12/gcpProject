output "app_url" {
  description = "The deployed service, through the load balancer (it answers once Jenkins has built the first image)"
  value       = "http://${local.p.lb_ip}/flight/booking/"
}

output "image_repository" { value = local.image_repository }

output "jenkins_url" {
  description = "Jenkins on its own public IP (HTTPS, self-signed certificate: the browser warns once). Without ui_source_ranges it is the tunnel address."
  value       = local.jenkins_url
}

output "jenkins_tunnel_command" {
  description = "Alternative that works from anywhere you can run gcloud: run this, leave it open, then browse to http://localhost:8080 (in Cloud Shell: Web Preview on port 8080)"
  value       = "gcloud compute ssh jenkins --zone ${var.zone} --project ${var.project_id} --tunnel-through-iap -- -L 8080:localhost:8080"
}

output "jenkins_user" { value = "admin" }

output "jenkins_admin_password" {
  value     = random_password.jenkins.result
  sensitive = true
}

output "cluster_credentials_command" {
  description = "Points kubectl at the flight cluster"
  value       = "gcloud container clusters get-credentials flight-cluster --zone ${var.zone} --project ${var.project_id}"
}

output "argocd_url" {
  description = "Argo CD on its own public IP (HTTPS, self-signed certificate: the browser warns once). Without ui_source_ranges use the port-forward command."
  value       = local.public ? "https://${google_compute_address.argocd[0].address}/" : "http://localhost:8081 (run argocd_port_forward_command)"
}

output "argocd_port_forward_command" {
  description = "Only needed without ui_source_ranges. Run this, leave it open, then browse to http://localhost:8081 (in Cloud Shell: Web Preview on port 8081)"
  value       = "kubectl port-forward -n argocd svc/argocd-server 8081:80"
}

output "argocd_user" { value = "admin" }

output "argocd_admin_password" {
  value     = data.kubernetes_secret_v1.argocd_admin.data["password"]
  sensitive = true
}
