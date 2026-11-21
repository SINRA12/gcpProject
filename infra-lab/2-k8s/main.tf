# Stage 2: inside each cluster, install ingress-nginx (behind an internal
# load balancer on the IP reserved in stage 1) and deploy the demo services.

terraform {
  required_version = ">= 1.5"

  # Bucket and prefix are passed at init time by lab.sh (-backend-config)
  backend "gcs" {}

  required_providers {
    google     = { source = "hashicorp/google", version = "~> 6.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.35" }
    helm       = { source = "hashicorp/helm", version = "~> 2.17" }
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

provider "kubernetes" {
  alias                  = "payment"
  host                   = "https://${local.p.clusters.payment.endpoint}"
  token                  = data.google_client_config.me.access_token
  cluster_ca_certificate = base64decode(local.p.clusters.payment.ca_cert)
}

provider "helm" {
  alias = "payment"
  kubernetes {
    host                   = "https://${local.p.clusters.payment.endpoint}"
    token                  = data.google_client_config.me.access_token
    cluster_ca_certificate = base64decode(local.p.clusters.payment.ca_cert)
  }
}

# ---------- What runs in each cluster ----------

module "flight" {
  source     = "./modules/cluster-apps"
  providers  = { kubernetes = kubernetes.flight, helm = helm.flight }
  ingress_ip = local.p.ingress_ips.flight

  apps = {
    "flight-cart-be"    = { namespace = "flight-cart-be-ns", path = "/flight/cart" }
    "flight-checkin-be" = { namespace = "flight-checkin-be-ns", path = "/flight/checkin" }
  }
}

module "payment" {
  source     = "./modules/cluster-apps"
  providers  = { kubernetes = kubernetes.payment, helm = helm.payment }
  ingress_ip = local.p.ingress_ips.payment

  apps = {
    "payment-be" = { namespace = "payment-be-ns", path = "/payment" }
  }
}
