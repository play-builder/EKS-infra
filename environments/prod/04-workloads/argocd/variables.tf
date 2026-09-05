variable "aws_region" {
  description = "AWS Region"
  type        = string

  validation {
    condition     = contains(["ap-northeast-2", "us-east-1"], var.aws_region)
    error_message = "aws_region must be ap-northeast-2 or us-east-1."
  }
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"

  validation {
    condition     = var.environment == "prod"
    error_message = "This root module is only for the prod cluster."
  }
}

variable "project_name" {
  description = "Project name used by the remote-state bucket"
  type        = string
  default     = "playdevops"
}

variable "course_id" {
  description = "Unique CourseId binding this workload root to cleanup evidence"
  type        = string
  default     = "course-2026"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{7,62}$", var.course_id))
    error_message = "course_id must be a unique 8-63 character lowercase identifier."
  }
}

variable "argocd_chart_version" {
  description = "Pinned argo-cd Helm chart version"
  type        = string
  default     = "10.4.3"
}

variable "argo_rollouts_chart_version" {
  description = "Pinned argo-rollouts Helm chart version"
  type        = string
  default     = "2.42.0"
}

variable "gateway_plugin_version" {
  description = "Pinned Gateway API traffic router plugin version"
  type        = string
  default     = "0.16.0"
}


variable "gateway_plugin_digest" {
  description = "Immutable multi-architecture index digest for the Gateway API traffic router plugin"
  type        = string
  default     = "sha256:af5aaba7e34c2b8eb0d52128ac91cb913f065b710c7dea88db59d626a96c53c2"
}

variable "gitops_repo_url" {
  description = "HTTPS clone URL of the argocd-gitops repository"
  type        = string
}

variable "gitops_target_revision" {
  description = "Git revision Argo CD tracks"
  type        = string
  default     = "main"
}

variable "bootstrap_path" {
  description = "Optional override. Empty means argocd/bootstrap/prod."
  type        = string
  default     = ""
}

variable "enable_bootstrap" {
  description = "Create the root Argo CD Application after the repository is reachable"
  type        = bool
  default     = false
}
variable "tags" { type = map(string) }
variable "argocd_platform" { type = object({ server_replicas = number, repo_server_replicas = number, controller_replicas = number, applicationset_replicas = number, redis_ha = bool, node_count = number, az_count = number, public_url = string, oidc_issuer_url = string, oidc_client_id = string, admin_group = string, readonly_group = string }) }
