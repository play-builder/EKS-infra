variable "aws_region" {
  type = string
  validation {
    condition     = contains(["ap-northeast-2", "us-east-1"], var.aws_region)
    error_message = "aws_region must be ap-northeast-2 or us-east-1."
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

variable "org_id" {
  description = "AWS Organizations ID. Every account in the Organization may pull images."
  type        = string
  validation {
    condition     = can(regex("^o-[a-z0-9]{10,32}$", var.org_id))
    error_message = "org_id must look like o-xxxxxxxxxx."
  }
}

variable "github_owner" {
  description = "GitHub owner login of the mini-commerce fork"
  type        = string
}

variable "github_owner_id" {
  description = "Numeric GitHub owner ID (gh api repos/<owner>/<repo> --jq .owner.id)"
  type        = string
  validation {
    condition     = can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must be numeric."
  }
}

variable "app_repository_name" {
  type    = string
  default = "mini-commerce"
}

variable "app_repository_id" {
  description = "Numeric GitHub repository ID of the mini-commerce fork (gh api repos/<owner>/<repo> --jq .id)"
  type        = string
  validation {
    condition     = can(regex("^[0-9]+$", var.app_repository_id))
    error_message = "app_repository_id must be numeric."
  }
}

variable "oidc_provider_mode" {
  description = "create: this root creates the GitHub OIDC provider. external: reference an existing one."
  type        = string
  default     = "create"
  validation {
    condition     = contains(["create", "external"], var.oidc_provider_mode)
    error_message = "oidc_provider_mode must be create or external."
  }
}

variable "external_oidc_provider_arn" {
  type    = string
  default = null
}

variable "ecr_keep_last_images" {
  description = "Number of sha- tagged images retained by the lifecycle policy"
  type        = number
  default     = 30
  validation {
    condition     = var.ecr_keep_last_images >= 10
    error_message = "Keep at least 10 images so rollback targets survive."
  }
}
