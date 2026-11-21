# One cluster's contents: ingress-nginx plus a set of demo services,
# each in its own namespace with a Deployment, Service and Ingress rule.

terraform {
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes" }
    helm       = { source = "hashicorp/helm" }
  }
}

resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  version          = var.ingress_chart_version
  namespace        = "ingress-nginx"
  create_namespace = true
  wait             = true # waits until the internal load balancer has its IP
  timeout          = 600

  values = [yamlencode({
    controller = {
      replicaCount = 2
      service = {
        annotations    = { "networking.gke.io/load-balancer-type" = "Internal" }
        loadBalancerIP = var.ingress_ip
      }
      config = { "use-forwarded-headers" = "true" }
      # Exposes request counts and latency histograms on port 10254 for Prometheus (stage 5)
      metrics = { enabled = true }
      # The Ingresses here have no host and clients use the load balancer IP, which
      # ingress-nginx treats as an undefined host and, by default, leaves out of the
      # metrics. This keeps those requests. Fine for a lab; on a public IP, scanners
      # sending random Host headers would each create a new series.
      extraArgs = { "metrics-per-undefined-host" = "true" }
    }
  })]
}

resource "kubernetes_namespace_v1" "ns" {
  for_each = var.apps
  metadata { name = each.value.namespace }
}

resource "kubernetes_deployment_v1" "app" {
  for_each = var.apps

  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.ns[each.key].metadata[0].name
    labels    = { app = each.key }
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = { app = each.key }
    }

    template {
      metadata {
        labels = { app = each.key }
      }

      spec {
        container {
          name  = "whoami"
          image = "traefik/whoami:v1.10.1"
          args  = ["--port", "8080", "--name", each.key]

          port {
            container_port = 8080
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 8080
            }
            period_seconds = 5
          }

          resources {
            requests = { cpu = "50m", memory = "32Mi" }
            limits   = { memory = "64Mi" }
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "app" {
  for_each = var.apps

  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.ns[each.key].metadata[0].name
  }

  spec {
    selector = { app = each.key }
    port {
      port        = 80
      target_port = 8080
    }
  }
}

resource "kubernetes_ingress_v1" "app" {
  for_each = var.apps

  metadata {
    name      = each.key
    namespace = kubernetes_namespace_v1.ns[each.key].metadata[0].name
  }

  spec {
    ingress_class_name = "nginx"
    rule {
      http {
        path {
          path      = each.value.path
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service_v1.app[each.key].metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  # ingress-nginx's admission webhook must be running before rules are created
  depends_on = [helm_release.ingress_nginx]
}
