variable "github_owner" {
  description = "GitHub owner of the forks"
  type        = string
}

variable "gitops_repository" {
  type    = string
  default = "argocd-gitops"
}

variable "required_check" {
  description = "Status check context that must pass before merge"
  type        = string
  default     = "validate"
}
