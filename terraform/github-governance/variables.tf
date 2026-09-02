variable "github_owner" {
  description = "GitHub owner of the course repositories"
  type        = string
}

variable "gitops_repository" {
  description = "Repository name without the owner"
  type        = string
  default     = "argocd-gitops"
}

variable "required_check" {
  description = "GitHub Actions check required before merge"
  type        = string
  default     = "validate"
}
