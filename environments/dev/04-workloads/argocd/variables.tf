variable "aws_region" {
  description = "AWS Region"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"

  validation {
    condition     = var.environment == "dev"
    error_message = "This root module is only for the dev cluster."
  }
}

variable "project_name" {
  description = "Project name used by the remote-state bucket"
  type        = string
  default     = "playdevops"
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
  description = "Optional override. Empty means argocd/bootstrap/dev."
  type        = string
  default     = ""
}

variable "enable_bootstrap" {
  description = "Create the root Argo CD Application after the repository is reachable"
  type        = bool
  default     = false
}
