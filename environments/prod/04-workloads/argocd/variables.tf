variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
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
