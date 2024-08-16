variable "role_name" {
  description = "GitHub Actions IAM Role 이름"
  type        = string
  default     = "GitHubActionsRole"
}

variable "github_org" {
  description = "GitHub Organization 이름"
  type        = string
  # 예: "your-company"
}

variable "github_repo" {
  description = "GitHub Repository 이름"
  type        = string
  # 예: "eks-infrastructure"
}