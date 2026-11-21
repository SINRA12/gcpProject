output "url" { value = "https://${var.record_name}.${var.domain}" }

output "origin_cert_pem" {
  value = cloudflare_origin_ca_certificate.origin.certificate
}

output "origin_key_pem" {
  value     = tls_private_key.origin.private_key_pem
  sensitive = true
}
