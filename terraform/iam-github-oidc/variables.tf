variable "aws_region" {
  description = "AWS Region"
  type        = string

  validation {
    condition     = contains(["ap-northeast-2", "us-east-1"], var.aws_region)
    error_message = "aws_region must be ap-northeast-2 or us-east-1."
  }
}

variable "project_name" {
  description = "Project name used by state buckets and shared resources"
  type        = string
  default     = "playdevops"
}

variable "course_id" {
  description = "Unique ownership boundary for this course run"
  type        = string
  default     = "replace-with-unique-course-id"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{7,62}$", var.course_id))
    error_message = "course_id must be a unique 8-63 character lowercase identifier."
  }
}

variable "oidc_provider_mode" {
  description = "Create a course-owned GitHub OIDC provider or reference an existing account-wide provider"
  type        = string
  default     = "create"

  validation {
    condition     = contains(["create", "external"], var.oidc_provider_mode)
    error_message = "oidc_provider_mode must be create or external."
  }
}

variable "external_oidc_provider_arn" {
  description = "Existing GitHub Actions OIDC provider ARN when oidc_provider_mode is external"
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = var.oidc_provider_mode != "external" || (
      var.external_oidc_provider_arn != null &&
      can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.external_oidc_provider_arn))
    )
    error_message = "external mode requires the exact token.actions.githubusercontent.com provider ARN."
  }
}

variable "github_org" {
  description = "GitHub organization"
  type        = string
  default     = "play-builder"
}

variable "infra_role_name" {
  description = "GitHub Actions role for EKS-infra"
  type        = string
  default     = "playdevops-github-eks-infra"
}

variable "infra_oidc_subjects" {
  description = "Exact GitHub OIDC subjects allowed to assume the infrastructure role"
  type        = set(string)
  default = [
    "repo:play-builder@42942042/EKS-infra@405337777:ref:refs/heads/main"
  ]
}

variable "state_bucket_arns" {
  description = "Exact S3 bucket ARNs that store Terraform state and native lock files"
  type        = set(string)

  validation {
    condition = length(var.state_bucket_arns) > 0 && alltrue([
      for arn in var.state_bucket_arns :
      can(regex("^arn:aws[a-z-]*:s3:::[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", arn))
    ])
    error_message = "state_bucket_arns must contain only exact S3 bucket ARNs without object wildcards."
  }
}

variable "sample_app_push_role_name" {
  description = "GitHub Actions role that can push only the sample-app image"
  type        = string
  default     = "playdevops-github-sample-app-push"
}

variable "sample_app_supply_chain_role_name" {
  description = "GitHub Actions role for sample-app attestation and verification"
  type        = string
  default     = "playdevops-github-sample-app-supply-chain"
}

variable "sample_app_supply_chain_oidc_subject" {
  description = "Immutable GitHub OIDC subject for the sample-app main branch supply-chain workflow"
  type        = string
  default     = "repo:play-builder@42942042/cicd-course-sample-app@1352247019:ref:refs/heads/main"

  validation {
    condition     = can(regex("^repo:[^/@]+@[0-9]+/cicd-course-sample-app@[0-9]+:ref:refs/heads/main$", var.sample_app_supply_chain_oidc_subject))
    error_message = "sample_app_supply_chain_oidc_subject must be an immutable numeric owner/repository subject for the sample-app main branch."
  }
}

variable "sample_app_oidc_subjects" {
  description = "Exact GitHub OIDC subjects allowed to push sample-app images"
  type        = set(string)
  default = [
    "repo:play-builder@42942042/cicd-course-sample-app@1352247019:ref:refs/heads/main",
    "repo:play-builder@42942042/cicd-course-sample-app@1352247019:ref:refs/heads/dev"
  ]
}

variable "sample_app_ecr_repository" {
  description = "Private ECR repository for sample-app OCI images"
  type        = string
  default     = "playdevops/sample-app"
}

variable "helm_chart_ecr_repository" {
  description = "Private ECR repository for sample-app Helm OCI artifacts"
  type        = string
  default     = "playdevops/sample-app-chart"
}

variable "ecr_keep_last_images" {
  description = "Number of tagged course images kept in ECR"
  type        = number
  default     = 30

  validation {
    condition     = var.ecr_keep_last_images >= 10
    error_message = "ecr_keep_last_images must be at least 10."
  }
}

variable "tags" {
  description = "Additional resource tags"
  type        = map(string)
  default     = {}
}
