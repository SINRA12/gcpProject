variable "project_id" { type = string }
variable "region" { type = string }
variable "zone" { type = string }

variable "state_bucket" {
  description = "GCS bucket holding Terraform state for all stages"
  type        = string
}

variable "ui_source_ranges" {
  description = "CIDRs allowed to reach the Jenkins and Argo CD web UIs on their own public IPs (HTTPS, self-signed certificates, protected by their logins). The default 0.0.0.0/0 means anyone on the internet can reach the login pages. Use specific CIDRs to restrict it. Empty: no public IPs at all, and both UIs are reachable only through the IAP tunnel and kubectl port-forward (scripts/laptop-access.sh). Each public UI uses one regional IN_USE_ADDRESSES (the quota is 4 on new projects)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
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
