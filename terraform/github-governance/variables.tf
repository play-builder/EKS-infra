variable "aws_region" {
  description = "Course Region used to bind governance evidence"
  type        = string
  default     = "ap-northeast-2"

  validation {
    condition     = contains(["ap-northeast-2", "us-east-1"], var.aws_region)
    error_message = "aws_region must be ap-northeast-2 or us-east-1."
  }
}

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
