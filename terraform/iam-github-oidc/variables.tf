variable "role_name" {
  description = "GitHub Actions IAM Role name"
  type        = string
  default     = "GitHubActionsRole"
}

variable "github_org" {
  description = "GitHub Organization name"
  type        = string
}

variable "github_repo" {
  description = "GitHub Repository name"
  type        = string
}
