variable "ingress_ip" {
  description = "Reserved internal IP for this cluster's ingress-nginx load balancer"
  type        = string
}

variable "apps" {
  description = "Demo services: name => { namespace, path }"
  type = map(object({
    namespace = string
    path      = string
  }))
}

variable "replicas" {
  type    = number
  default = 2
}

variable "ingress_chart_version" {
  type    = string
  default = "4.12.0"
}
