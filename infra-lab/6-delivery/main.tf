# Stage 6: delivery. Jenkins builds the application image, Argo CD deploys it.
#
#   Jenkins (a VM)  --push image-->  Artifact Registry
#        |
#        +--commit new image tag-->  Git (gitops/flight/flight-booking-be/values.yaml)
#                                       ^
#   Argo CD (in the flight cluster) ----+  pulls Git and makes the cluster match it
#
# Jenkins has no access to the cluster: its service account may only write to the registry.
# Argo CD runs inside the cluster, so nothing outside needs credentials to deploy.
# The registry itself is created by lab.sh and not managed here, so it survives ./lab.sh down.

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

  image_repository = "${var.region}-docker.pkg.dev/${var.project_id}/${var.ar_repo}/flight-booking-be"

  # Pinned on purpose: bump deliberately. This Jenkins needs Java 21 or 25 (the VM image and the JDK
  # package in jenkins/startup.sh.tftpl follow from that). The checksum is published next to the download at
  # https://get.jenkins.io/war-stable/<version>/jenkins.war.sha256
  jenkins_version        = "2.580.2"
  jenkins_war_sha256     = "d98032d2401c540a35613a82ed358921fcf3166d5e6eaaaf60a7941845be3251"
  plugin_manager_version = "2.16.0"
  trivy_version          = "0.76.2"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_project" "this" {}

# Short-lived access token from your gcloud credentials
data "google_client_config" "me" {}

# Argo CD goes into the flight cluster, which is also where the application runs
provider "kubernetes" {
  host                   = "https://${local.p.clusters.flight.endpoint}"
  token                  = data.google_client_config.me.access_token
  cluster_ca_certificate = base64decode(local.p.clusters.flight.ca_cert)
}

provider "helm" {
  kubernetes {
    host                   = "https://${local.p.clusters.flight.endpoint}"
    token                  = data.google_client_config.me.access_token
    cluster_ca_certificate = base64decode(local.p.clusters.flight.ca_cert)
  }
}

# ---------- Jenkins ----------

# The identity the Jenkins VM runs as. It can write images to one registry and do nothing else.
resource "google_service_account" "jenkins" {
  account_id   = "jenkins-ci"
  display_name = "Jenkins CI (pushes images only)"
}

resource "google_artifact_registry_repository_iam_member" "jenkins_push" {
  location   = var.region
  repository = var.ar_repo
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.jenkins.email}"
}

# The GKE nodes pull the images. Their node pool uses the project's default compute service
# account, so give that one read access to the registry.
resource "google_artifact_registry_repository_iam_member" "nodes_pull" {
  location   = var.region
  repository = var.ar_repo
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${data.google_project.this.number}-compute@developer.gserviceaccount.com"
}

# Read it with: ./lab.sh outputs delivery
resource "random_password" "jenkins" {
  length  = 24
  special = false
}

# Jenkins' own public IP, so it can be reached from your laptop. It is not behind the load balancer.
resource "google_compute_address" "jenkins" {
  name         = "jenkins-ip"
  region       = var.region
  address_type = "EXTERNAL"
}

data "google_compute_subnetwork" "lab" {
  self_link = local.p.subnet_self_link
}

# Only your IPs may connect, and only to the HTTPS port. With no IPs listed there is no rule at all,
# and the only way in is the IAP tunnel.
resource "google_compute_firewall" "jenkins_ui" {
  count         = length(var.my_ips) > 0 ? 1 : 0
  name          = "lab-allow-jenkins-ui"
  network       = data.google_compute_subnetwork.lab.network
  source_ranges = var.my_ips
  target_tags   = ["jenkins"]

  allow {
    protocol = "tcp"
    ports    = ["8443"]
  }
}

resource "google_compute_instance" "jenkins" {
  name                      = "jenkins"
  machine_type              = var.jenkins_machine_type
  zone                      = var.zone
  tags                      = ["jenkins"]
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      # Debian 13, not 12: Jenkins 2.580 needs Java 21 or 25, and only Debian 13 packages JDK 21
      image = "debian-cloud/debian-13"
      size  = 30
      type  = "pd-balanced"
    }
  }

  # The access_config block gives the VM its own public IP. Who may connect is decided by the
  # firewall rule above (your IPs only). The IAP tunnel (the lab-allow-iap-ssh rule) still works too.
  network_interface {
    subnetwork = local.p.subnet_self_link

    access_config {
      nat_ip = google_compute_address.jenkins.address
    }
  }

  service_account {
    email  = google_service_account.jenkins.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    startup-script = templatefile("${path.module}/jenkins/startup.sh.tftpl", {
      jenkins_version        = local.jenkins_version
      jenkins_war_sha256     = local.jenkins_war_sha256
      plugin_manager_version = local.plugin_manager_version
      trivy_version          = local.trivy_version
      plugins                = file("${path.module}/jenkins/plugins.txt")
      public_ip              = google_compute_address.jenkins.address
      jcasc = templatefile("${path.module}/jenkins/jenkins.yaml.tftpl", {
        project_id   = var.project_id
        region       = var.region
        ar_repo      = var.ar_repo
        git_repo_url = var.git_repo_url
        jenkins_url  = "https://${google_compute_address.jenkins.address}:8443/"
      })
    })

    # Read by the startup script. Instance metadata is fine for a lab; a team would keep these in
    # Secret Manager.
    jenkins-admin-password = random_password.jenkins.result
    github-token           = var.github_token
  }

  depends_on = [
    google_artifact_registry_repository_iam_member.jenkins_push,
  ]
}

# ---------- Argo CD ----------

# A slim install: no Dex (single sign-on), no notifications, no ApplicationSet controller. The lab
# has one user, one application and little spare CPU.
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 600

  values = [yamlencode({
    # Remove the CRDs with the chart, so ./lab.sh down delivery leaves nothing behind
    crds = { keep = false }

    dex           = { enabled = false }
    notifications = { enabled = false }
    applicationSet = {
      replicas = 0
    }

    configs = {
      cm = {
        # How often Argo CD looks at Git for changes (the default is 120s plus up to 60s of jitter)
        "timeout.reconciliation"        = "60s"
        "timeout.reconciliation.jitter" = "10s"
      }
      params = {
        # Plain HTTP inside the cluster. The only way in is kubectl port-forward, and plain HTTP
        # works with Cloud Shell's Web Preview (a self-signed certificate does not).
        "server.insecure" = true
      }
    }

    controller = {
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { memory = "512Mi" }
      }
    }
    server = {
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "256Mi" }
      }
    }
    repoServer = {
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { memory = "512Mi" }
      }
    }
    redis = {
      resources = {
        requests = { cpu = "25m", memory = "32Mi" }
        limits   = { memory = "128Mi" }
      }
    }
  })]
}

# The Application: "keep the cluster matching charts/java-service plus gitops/.../values.yaml".
# It is created through a second chart because a plain Terraform resource for an Argo CD
# Application cannot be planned before Argo CD's CRDs exist.
resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version
  namespace  = "argocd"
  wait       = true
  timeout    = 300

  values = [yamlencode({
    applications = {
      "flight-booking-be" = {
        namespace = "argocd"
        project   = "default"
        # Deleting the Application also deletes what it deployed
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        source = {
          repoURL        = var.git_repo_url
          targetRevision = var.gitops_revision
          path           = "charts/java-service"
          helm = {
            # Relative to the chart folder: the per-service settings and the image tag Jenkins writes
            valueFiles = ["../../gitops/flight/flight-booking-be/values.yaml"]
            # Set here, not in Git, so the GCP project id stays out of the repository
            parameters = [
              { name = "image.repository", value = local.image_repository },
            ]
          }
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = "flight-booking-be-ns"
        }
        syncPolicy = {
          automated = {
            prune    = true # remove what Git no longer has
            selfHeal = true # undo changes made by hand with kubectl
          }
          syncOptions = ["CreateNamespace=true"]
        }
      }
    }
  })]

  depends_on = [
    helm_release.argocd,
    google_artifact_registry_repository_iam_member.nodes_pull,
  ]
}

# Argo CD generates the first admin password itself and stores it in this secret
data "kubernetes_secret_v1" "argocd_admin" {
  metadata {
    name      = "argocd-initial-admin-secret"
    namespace = "argocd"
  }

  depends_on = [helm_release.argocd]
}
