variable "project_id" { type = string }
variable "region" { type = string }
variable "zone" { type = string }

variable "state_bucket" {
  description = "GCS bucket holding Terraform state for all stages"
  type        = string
}

variable "my_ips" {
  description = "CIDRs allowed to reach the Jenkins web UI on its own public IP (HTTPS, port 8443). The same list as 4-edge uses for Cloud Armor. Empty: no firewall rule, so Jenkins is reachable only through the IAP tunnel."
  type        = list(string)
  default     = []
}

variable "ar_repo" {
  description = "Artifact Registry repository for the application images. lab.sh creates it once and ./lab.sh down leaves it, so the tag recorded in Git keeps pointing at an image that exists."
  type        = string
  default     = "lab-apps"
}

variable "git_repo_url" {
  description = "HTTPS URL of the Git repository that Jenkins builds from and Argo CD deploys from (it must hold apps/, charts/ and gitops/)"
  type        = string
  default     = "https://github.com/SINRA12/gcpProject.git"
}

variable "gitops_revision" {
  description = "Branch or tag Argo CD follows. Jenkins records new image tags on main, so leave this as main unless you are testing the chart from a branch."
  type        = string
  default     = "main"
}

variable "github_token" {
  description = "GitHub token with write access to the repository (contents: read and write), so Jenkins can commit the new image tag. lab.sh passes it from the GITHUB_TOKEN environment variable. Empty: Jenkins still builds and pushes images, but cannot record the tag."
  type        = string
  sensitive   = true
  default     = ""
}

variable "jenkins_machine_type" {
  description = "Machine type of the Jenkins VM. Jenkins plus a Maven build wants about 2 vCPU and 8 GB."
  type        = string
  default     = "e2-standard-2"
}

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version (installs Argo CD v3.6.2)"
  type        = string
  default     = "10.18.2"
}

variable "argocd_apps_chart_version" {
  description = "argocd-apps Helm chart version (creates the Argo CD Application objects)"
  type        = string
  default     = "2.0.8"
}
