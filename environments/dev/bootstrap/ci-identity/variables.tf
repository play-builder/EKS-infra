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
    condition     = contains(["dev", "prod", "recovery"], var.environment)
    error_message = "environment must be dev, prod or recovery."
  }
}

variable "project_name" {
  type    = string
  default = "mini-commerce"
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
    condition     = can(regex("^[1-9][0-9]*$", var.github_owner_id))
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
    condition     = can(regex("^[1-9][0-9]*$", var.infra_repository_id))
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

variable "external_ci_roles" {
  description = "Externally owned, distinct plan/apply/drift roles. Empty disables CI. Pin each reviewed customer-managed permissions boundary by canonical JSON SHA-256."
  type = map(object({
    role_arn                           = string
    permissions_boundary_arn           = string
    permissions_boundary_policy_sha256 = string
  }))
  default = {}
  validation {
    condition = length(var.external_ci_roles) == 0 || (
      toset(keys(var.external_ci_roles)) == toset(["plan", "apply", "drift"]) &&
      length(toset([for r in var.external_ci_roles : r.role_arn])) == 3 &&
      alltrue([for r in var.external_ci_roles :
        can(regex("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$", r.role_arn)) &&
        can(regex("^arn:aws:iam::[0-9]{12}:policy/[A-Za-z0-9+=,.@_/-]+$", r.permissions_boundary_arn)) &&
        can(regex("^[a-f0-9]{64}$", r.permissions_boundary_policy_sha256))
      ])
    )
    error_message = "Supply exactly three distinct plan/apply/drift roles and reviewed customer-managed boundary ARNs/hashes, or leave the map empty to disable CI."
  }
}

variable "enable_external_ci_roles" {
  description = "Enable role data verification and CI outputs only after the external owner provisions the exported contract. False permits preparing the contract without IAM reads of not-yet-created roles."
  type        = bool
  default     = false
  validation {
    condition     = !var.enable_external_ci_roles || length(var.external_ci_roles) == 3
    error_message = "Enabling external CI roles requires a complete plan/apply/drift role mapping."
  }
}
