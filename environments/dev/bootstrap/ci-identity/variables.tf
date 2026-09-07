variable "aws_region" {
  type = string
  validation {
    condition     = contains(["ap-northeast-2", "us-east-1"], var.aws_region)
    error_message = "aws_region must be ap-northeast-2 or us-east-1."
  }
}

variable "environment" {
  type    = string
  default = "dev"
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "project_name" {
  type    = string
  default = "mini-commerce"
}

variable "course_id" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{7,62}$", var.course_id))
    error_message = "course_id must be an 8-63 character lowercase identifier."
  }
}

variable "state_bucket_name" {
  description = "This account's Terraform state bucket (bootstrap/state-backend output)"
  type        = string
}

variable "github_owner" {
  type = string
}

variable "github_owner_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must be numeric."
  }
}

variable "infra_repository_name" {
  type    = string
  default = "EKS-infra"
}

variable "infra_repository_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]+$", var.infra_repository_id))
    error_message = "infra_repository_id must be numeric."
  }
}

variable "oidc_provider_mode" {
  type    = string
  default = "create"
  validation {
    condition     = contains(["create", "external"], var.oidc_provider_mode)
    error_message = "oidc_provider_mode must be create or external."
  }
}

variable "external_oidc_provider_arn" {
  type    = string
  default = null
}
