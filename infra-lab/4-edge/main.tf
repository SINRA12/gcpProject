# Stage 4: HAProxy managed instance group, Classic Application Load Balancer,
# Cloud Armor, and (when Cloudflare is enabled) HTTPS with the origin certificate.

terraform {
  required_version = ">= 1.5"

  # Bucket and prefix are passed at init time by lab.sh (-backend-config)
  backend "gcs" {}

  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
    http   = { source = "hashicorp/http", version = "~> 3.4" }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "terraform_remote_state" "platform" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "infra-lab/1-platform"
  }
}

data "terraform_remote_state" "cf" {
  count   = var.enable_cloudflare ? 1 : 0
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "infra-lab/3-cloudflare"
  }
}

locals {
  p = data.terraform_remote_state.platform.outputs
}

# ---------- HAProxy ----------

resource "google_compute_instance_template" "haproxy" {
  name_prefix  = "haproxy-"
  machine_type = "e2-small"
  tags         = ["haproxy"]

  disk {
    source_image = "debian-cloud/debian-12"
    auto_delete  = true
    boot         = true
  }

  # No access_config block = no public IP; outbound goes through Cloud NAT
  network_interface {
    subnetwork = local.p.subnet_self_link
  }

  metadata = {
    startup-script = templatefile("${path.module}/haproxy-startup.sh.tftpl", {
      flight_ip  = local.p.ingress_ips.flight
      payment_ip = local.p.ingress_ips.payment
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_health_check" "haproxy" {
  name                = "haproxy-hc"
  check_interval_sec  = 5
  timeout_sec         = 3
  healthy_threshold   = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 80
    request_path = "/haproxy-health"
  }
}

resource "google_compute_region_instance_group_manager" "haproxy" {
  name               = "haproxy-mig"
  region             = var.region
  base_instance_name = "haproxy"
  target_size        = var.haproxy_count

  version {
    instance_template = google_compute_instance_template.haproxy.id
  }

  # Roll out a changed template (for example a new HAProxy config) to the VMs by itself.
  # Without this the group keeps its existing VMs and only new ones get the new template.
  # Surge: start up to 3 new VMs first (one per zone), delete old ones only once the new
  # ones are healthy, so there is no gap in service.
  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 3
    max_unavailable_fixed = 0
  }

  named_port {
    name = "http"
    port = 80
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.haproxy.id
    initial_delay_sec = 120
  }
}

# ---------- Cloud Armor ----------

data "http" "cf_ipv4" {
  count = var.enable_cloudflare ? 1 : 0
  url   = "https://www.cloudflare.com/ips-v4"
}

data "http" "cf_ipv6" {
  count = var.enable_cloudflare ? 1 : 0
  url   = "https://www.cloudflare.com/ips-v6"
}

locals {
  cloudflare_ranges = var.enable_cloudflare ? concat(
    split("\n", trimspace(data.http.cf_ipv4[0].response_body)),
    split("\n", trimspace(data.http.cf_ipv6[0].response_body)),
  ) : []

  # A basic Cloud Armor rule takes at most 10 ranges, so split into chunks
  allow_chunks = chunklist(concat(var.my_ips, local.cloudflare_ranges), 10)
}

resource "google_compute_security_policy" "armor" {
  count = var.enable_armor ? 1 : 0
  name  = "lab-armor"

  # Block SQL injection attempts, even from allowed sources
  rule {
    action   = "deny(403)"
    priority = 900
    match {
      expr {
        expression = "evaluatePreconfiguredWaf('sqli-v33-stable')"
      }
    }
  }

  # Allow your IPs and (if enabled) Cloudflare's ranges
  dynamic "rule" {
    for_each = { for i, chunk in local.allow_chunks : i => chunk }
    content {
      action   = "allow"
      priority = 1000 + rule.key
      match {
        versioned_expr = "SRC_IPS_V1"
        config {
          src_ip_ranges = rule.value
        }
      }
    }
  }

  # Default: deny everyone else
  rule {
    action   = "deny(403)"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
  }
}

# ---------- Load balancer chain ----------

resource "google_compute_backend_service" "haproxy" {
  name                            = "haproxy-backend"
  load_balancing_scheme           = "EXTERNAL" # Classic Application LB
  protocol                        = "HTTP"
  port_name                       = "http"
  timeout_sec                     = 30
  connection_draining_timeout_sec = 30
  health_checks                   = [google_compute_health_check.haproxy.id]
  security_policy                 = var.enable_armor ? google_compute_security_policy.armor[0].id : null

  backend {
    group           = google_compute_region_instance_group_manager.haproxy.instance_group
    balancing_mode  = "UTILIZATION"
    max_utilization = 0.8
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

resource "google_compute_url_map" "lab" {
  name            = "lab-url-map"
  default_service = google_compute_backend_service.haproxy.id
}

resource "google_compute_target_http_proxy" "lab" {
  name    = "lab-http-proxy"
  url_map = google_compute_url_map.lab.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name                  = "lab-http-rule"
  load_balancing_scheme = "EXTERNAL"
  ip_address            = local.p.lb_ip_id
  port_range            = "80"
  target                = google_compute_target_http_proxy.lab.id
}

# ---------- HTTPS (only with Cloudflare) ----------

resource "google_compute_ssl_certificate" "cf_origin" {
  count       = var.enable_cloudflare ? 1 : 0
  name_prefix = "cf-origin-"
  certificate = data.terraform_remote_state.cf[0].outputs.origin_cert_pem
  private_key = data.terraform_remote_state.cf[0].outputs.origin_key_pem

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_target_https_proxy" "lab" {
  count            = var.enable_cloudflare ? 1 : 0
  name             = "lab-https-proxy"
  url_map          = google_compute_url_map.lab.id
  ssl_certificates = [google_compute_ssl_certificate.cf_origin[0].id]
}

resource "google_compute_global_forwarding_rule" "https" {
  count                 = var.enable_cloudflare ? 1 : 0
  name                  = "lab-https-rule"
  load_balancing_scheme = "EXTERNAL"
  ip_address            = local.p.lb_ip_id
  port_range            = "443"
  target                = google_compute_target_https_proxy.lab[0].id
}
