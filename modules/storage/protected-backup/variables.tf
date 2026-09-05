variable "bucket_name" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "Use a concrete DNS-safe bucket name without dots."
  }
}
variable "administrator_role_arns" {
  type = set(string)
  validation {
    condition     = length(var.administrator_role_arns) > 0 && alltrue([for arn in var.administrator_role_arns : can(regex("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$", arn))])
    error_message = "At least one exact IAM role administrator is required."
  }
}
variable "operator_role_arns" {
  type = set(string)
  validation {
    condition     = length(var.operator_role_arns) > 0 && alltrue([for arn in var.operator_role_arns : can(regex("^arn:aws:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/-]+$", arn))])
    error_message = "At least one exact backup/recovery IAM role is required."
  }
}
variable "retention_days" {
  type    = number
  default = 120
  validation {
    condition     = var.retention_days >= 90 && var.retention_days <= 3650 && floor(var.retention_days) == var.retention_days
    error_message = "Retention must be an integer from 90 to 3650 days."
  }
}
variable "tags" {
  type = map(string)
  validation {
    condition     = alltrue([for key in ["PlatformInstanceId", "Owner", "CostCenter", "Environment"] : try(length(trimspace(var.tags[key])) > 0, false)])
    error_message = "PlatformInstanceId, Owner, CostCenter and Environment are required."
  }
}
