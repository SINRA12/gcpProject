# Stage 3 (optional): Cloudflare side. A proxied DNS record pointing at the
# load balancer IP, and a Cloudflare Origin CA certificate that the Google
# load balancer will present to Cloudflare (used by stage 4).
# Auth: export CLOUDFLARE_API_TOKEN with Zone DNS Edit and SSL and Certificates Edit.

terraform {
  required_version = ">= 1.5"

  # Bucket and prefix are passed at init time by lab.sh (-backend-config)
  backend "gcs" {}

  required_providers {
    cloudflare = { source = "cloudflare/cloudflare", version = "~> 5.0" }
    tls        = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

provider "cloudflare" {}

data "terraform_remote_state" "platform" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "infra-lab/1-platform"
  }
}

resource "cloudflare_dns_record" "lab" {
  zone_id = var.cloudflare_zone_id
  name    = var.record_name
  type    = "A"
  content = data.terraform_remote_state.platform.outputs.lb_ip
  proxied = true
  ttl     = 1 # 1 = automatic, required for proxied records
}

# Origin certificate: key and CSR generated locally, signed by Cloudflare
resource "tls_private_key" "origin" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "origin" {
  private_key_pem = tls_private_key.origin.private_key_pem
  subject {
    common_name = var.domain
  }
}

resource "cloudflare_origin_ca_certificate" "origin" {
  csr                = tls_cert_request.origin.cert_request_pem
  hostnames          = [var.domain, "*.${var.domain}"]
  request_type       = "origin-rsa"
  requested_validity = 365
}
