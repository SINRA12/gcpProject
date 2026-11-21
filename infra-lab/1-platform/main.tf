# Stage 1: network, NAT, firewall, two GKE clusters and the reserved IPs
# the later stages need (internal ingress IPs and the global load balancer IP).

terraform {
  required_version = ">= 1.5"

  # Bucket and prefix are passed at init time by lab.sh (-backend-config)
  backend "gcs" {}

  required_providers {
    google = { source = "hashicorp/google", version = "~> 6.0" }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

locals {
  clusters = toset(["flight", "payment"])
}

resource "google_project_service" "apis" {
  for_each           = toset(["compute.googleapis.com", "container.googleapis.com"])
  service            = each.key
  disable_on_destroy = false
}

# ---------- Network ----------

resource "google_compute_network" "vpc" {
  name                    = "lab-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "subnet" {
  name          = "lab-subnet"
  network       = google_compute_network.vpc.id
  region        = var.region
  ip_cidr_range = "10.10.0.0/20"
}

resource "google_compute_router" "router" {
  name    = "lab-router"
  network = google_compute_network.vpc.id
  region  = var.region
}

# Outbound internet for machines with private IPs only (HAProxy VMs)
resource "google_compute_router_nat" "nat" {
  name                               = "lab-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# ---------- Firewall ----------

resource "google_compute_firewall" "internal" {
  name          = "lab-allow-internal"
  network       = google_compute_network.vpc.name
  source_ranges = ["10.0.0.0/8"]
  allow { protocol = "tcp" }
  allow { protocol = "udp" }
  allow { protocol = "icmp" }
}

resource "google_compute_firewall" "iap_ssh" {
  name          = "lab-allow-iap-ssh"
  network       = google_compute_network.vpc.name
  source_ranges = ["35.235.240.0/20"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# Google load balancer traffic and health checks -> HAProxy
resource "google_compute_firewall" "lb_health" {
  name          = "lab-allow-lb-health"
  network       = google_compute_network.vpc.name
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["haproxy"]
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
}

# ---------- GKE clusters ----------

resource "google_container_cluster" "cluster" {
  for_each = local.clusters

  name                = "${each.key}-cluster"
  location            = var.zone
  network             = google_compute_network.vpc.id
  subnetwork          = google_compute_subnetwork.subnet.id
  deletion_protection = false
  initial_node_count  = 2

  # VPC-native: pods get IPs from GKE-managed secondary ranges
  ip_allocation_policy {}

  release_channel {
    channel = "REGULAR"
  }

  node_config {
    machine_type = var.node_machine_type
    disk_size_gb = 30
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}

# ---------- Reserved IPs ----------

# Fixed private IP for each cluster's ingress-nginx internal load balancer,
# so HAProxy's config is known before the clusters are even populated.
resource "google_compute_address" "ingress" {
  for_each     = local.clusters
  name         = "${each.key}-ingress-ip"
  region       = var.region
  subnetwork   = google_compute_subnetwork.subnet.id
  address_type = "INTERNAL"
}

# Public anycast IP for the Classic Application Load Balancer
resource "google_compute_global_address" "lb" {
  name       = "lab-lb-ip"
  depends_on = [google_project_service.apis]
}
