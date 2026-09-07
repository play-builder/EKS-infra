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
    condition     = can(regex("^[1-9][0-9]*$", var.github_owner_id))
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
    condition     = can(regex("^[1-9][0-9]*$", var.app_repository_id))
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

variable "platform_image_publisher" {
  description = "Optional dedicated EKS-infra publisher. Null disables creation; IDs must come from live GitHub repository metadata."
  type = object({
    github_owner        = string
    github_owner_id     = string
    repository_name     = string
    repository_id       = string
    ecr_repository_name = string
  })
  default = null
  validation {
    condition = var.platform_image_publisher == null ? true : (
      can(regex("^[A-Za-z0-9][A-Za-z0-9-]*$", var.platform_image_publisher.github_owner)) &&
      can(regex("^[A-Za-z0-9_.-]+$", var.platform_image_publisher.repository_name)) &&
      can(regex("^[1-9][0-9]*$", var.platform_image_publisher.github_owner_id)) &&
      can(regex("^[1-9][0-9]*$", var.platform_image_publisher.repository_id)) &&
      can(regex("^[a-z0-9]+([._/-][a-z0-9]+)*$", var.platform_image_publisher.ecr_repository_name)) &&
      length(var.platform_image_publisher.ecr_repository_name) >= 2 &&
      length(var.platform_image_publisher.ecr_repository_name) <= 256 &&
      !contains([var.project_name, "${var.project_name}-chart"], var.platform_image_publisher.ecr_repository_name)
    )
    error_message = "Use verified positive numeric GitHub IDs and a dedicated valid ECR repository name distinct from app/chart."
  }
}

variable "registry_scanning" {
  description = "Account/region singleton. External is the safe default. Terraform ownership requires import and a reviewed full-registry handoff."
  type = object({
    ownership_mode                  = optional(string, "external")
    repository_filters              = optional(set(string), [])
    scan_on_push_repository_filters = optional(set(string), [])
    ownership_handoff = optional(object({
      account_id         = string
      aws_region         = string
      approval_reference = string
    }))
  })
  default = {}
}
