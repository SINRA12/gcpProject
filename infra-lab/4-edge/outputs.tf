output "lb_ip" { value = local.p.lb_ip }

output "test_commands" {
  value = <<-EOT
    gcloud compute backend-services get-health haproxy-backend --global
    curl -s http://${local.p.lb_ip}/flight/cart | grep -E 'Name|Hostname|X-Haproxy-Node|X-Forwarded-For'
    curl -s http://${local.p.lb_ip}/payment | grep -E 'Name|Hostname'
  EOT
}
