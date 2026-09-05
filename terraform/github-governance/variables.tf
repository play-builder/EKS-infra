variable "aws_region" {
  description = "AWS Region used to bind governance evidence"
  type        = string
  default     = "ap-northeast-2"

  validation {
    condition     = contains(["ap-northeast-2", "us-east-1"], var.aws_region)
    error_message = "aws_region must be ap-northeast-2 or us-east-1."
  }
}

variable "github_owner" {
  description = "GitHub owner of the managed repositories"
  type        = string
}

variable "course_id" {
  description = "Unique CourseId binding governance resources to cleanup evidence"
  type        = string
  default     = "course-2026"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{7,62}$", var.course_id))
    error_message = "course_id must be a unique 8-63 character lowercase identifier."
  }
}

variable "account_id" {
  description = "AWS account ID bound to governance evidence"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
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
