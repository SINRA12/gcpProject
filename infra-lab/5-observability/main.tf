# Stage 5: observability. Prometheus in both clusters, one Grafana (in the flight cluster,
# served at /grafana through the public load balancer) and dashboards defined as code.
#
# Where the numbers come from:
#   - ingress-nginx pods (both clusters): request counts and latency per app, scraped here
#   - HAProxy VMs: 4xx/5xx and response time per backend, scraped from :8404/metrics
#   - the Classic load balancer: Google's own metrics in Cloud Monitoring, read by Grafana

terraform {
  required_version = ">= 1.5"

  # Bucket and prefix are passed at init time by lab.sh (-backend-config)
  backend "gcs" {}

  required_providers {
    google     = { source = "hashicorp/google", version = "~> 6.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.35" }
    helm       = { source = "hashicorp/helm", version = "~> 2.17" }
    random     = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

data "terraform_remote_state" "platform" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "infra-lab/1-platform"
  }
}

locals {
  p = data.terraform_remote_state.platform.outputs

  grafana_root_url = var.grafana_root_url != "" ? var.grafana_root_url : "http://${local.p.lb_ip}/grafana/"
  haproxy_zones    = ["${var.region}-a", "${var.region}-b", "${var.region}-c"]
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# Short-lived access token from your gcloud credentials, used for both clusters
data "google_client_config" "me" {}

# ---------- Providers per cluster ----------

provider "kubernetes" {
  alias                  = "flight"
  host                   = "https://${local.p.clusters.flight.endpoint}"
  token                  = data.google_client_config.me.access_token
  cluster_ca_certificate = base64decode(local.p.clusters.flight.ca_cert)
}

provider "helm" {
  alias = "flight"
  kubernetes {
    host                   = "https://${local.p.clusters.flight.endpoint}"
    token                  = data.google_client_config.me.access_token
    cluster_ca_certificate = base64decode(local.p.clusters.flight.ca_cert)
  }
}

provider "helm" {
  alias = "payment"
  kubernetes {
    host                   = "https://${local.p.clusters.payment.endpoint}"
    token                  = data.google_client_config.me.access_token
    cluster_ca_certificate = base64decode(local.p.clusters.payment.ca_cert)
  }
}

# ---------- Supporting pieces ----------

# Grafana's admin password. Read it with: ./lab.sh outputs observability
resource "random_password" "grafana" {
  length  = 24
  special = false
}

# Fixed private IP so the flight cluster's Grafana can reach the payment cluster's Prometheus
resource "google_compute_address" "payment_prometheus" {
  name         = "payment-prometheus-ip"
  region       = var.region
  subnetwork   = local.p.subnet_self_link
  address_type = "INTERNAL"
}

# ---------- Prometheus (+ Grafana in flight) ----------

resource "helm_release" "flight" {
  provider         = helm.flight
  name             = "kps"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.chart_version
  namespace        = "monitoring"
  create_namespace = true
  wait             = true
  timeout          = 900

  values = [
    file("${path.module}/values/common.yaml"),
    templatefile("${path.module}/values/flight.yaml.tftpl", {
      project_id            = var.project_id
      zones                 = local.haproxy_zones
      root_url              = local.grafana_root_url
      payment_prometheus_ip = google_compute_address.payment_prometheus.address
    }),
  ]

  set_sensitive {
    name  = "grafana.adminPassword"
    value = random_password.grafana.result
  }
}

resource "helm_release" "payment" {
  provider         = helm.payment
  name             = "kps"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.chart_version
  namespace        = "monitoring"
  create_namespace = true
  wait             = true
  timeout          = 900

  values = [
    file("${path.module}/values/common.yaml"),
    templatefile("${path.module}/values/payment.yaml.tftpl", {
      payment_prometheus_ip = google_compute_address.payment_prometheus.address
    }),
  ]
}

# ---------- Dashboards as code ----------

# Every file in dashboards/ becomes a ConfigMap that Grafana's sidecar loads automatically.
# __PROJECT__ in the JSON is replaced with your project id (for the Cloud Monitoring panels).
resource "kubernetes_config_map_v1" "dashboards" {
  provider = kubernetes.flight
  for_each = fileset("${path.module}/dashboards", "*.json")

  metadata {
    name      = "dashboard-${trimsuffix(each.key, ".json")}"
    namespace = "monitoring"
    labels    = { grafana_dashboard = "1" }
  }

  data = {
    (each.key) = replace(file("${path.module}/dashboards/${each.key}"), "__PROJECT__", var.project_id)
  }

  depends_on = [helm_release.flight]
}
