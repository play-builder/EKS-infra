variable "name" {
  type = string
  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{1,180}$", var.name))
    error_message = "name must be a safe nonempty alias suffix."
  }
}
variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}
variable "account_id" {
  type = string
  validation {
    condition     = var.account_id == data.aws_caller_identity.current.account_id
    error_message = "account_id must match the active AWS provider account."
  }
  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12 digit AWS account ID."
  }
}
variable "aws_region" {
  type = string
  validation {
    condition     = var.aws_region == data.aws_region.current.name
    error_message = "aws_region must match the active AWS provider Region."
  }
  validation {
    condition     = contains(["ap-northeast-2", "us-east-1"], var.aws_region)
    error_message = "Use an approved workload Region."
  }
}
variable "tags" {
  type = map(string)
  validation {
    condition     = alltrue([for k in ["PlatformInstanceId", "Owner", "CostCenter", "Environment"] : try(trimspace(var.tags[k]) != "", false)]) && try(var.tags.Environment == var.environment, false)
    error_message = "Required nonempty platform tags must include the matching Environment."
  }
}

variable "administrator_role_arns" {
  description = "Exact same-account administrator roles, including the Terraform execution role that updates this key policy."
  type        = set(string)
  validation {
    condition     = length(var.administrator_role_arns) > 0 && alltrue([for arn in var.administrator_role_arns : can(regex("^arn:aws:iam::${var.account_id}:role/[A-Za-z0-9+=,.@_/-]+$", arn))])
    error_message = "KMS administrators must be explicit same-account IAM roles without wildcards."
  }
}
variable "caller_role_arns" {
  description = "Optional exact same-account log API caller roles. Compute role ARNs before creating the key to avoid cycles."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for arn in var.caller_role_arns : can(regex("^arn:aws:iam::${var.account_id}:role/[A-Za-z0-9+=,.@_/-]+$", arn))])
    error_message = "Log callers must be explicit same-account IAM roles."
  }
}
variable "log_group_names" {
  description = "Precomputed exact names including application AND performance; never downstream resource ARNs."
  type        = set(string)
  validation {
    condition     = length(var.log_group_names) > 0 && alltrue([for name in var.log_group_names : can(regex("^[A-Za-z0-9_./#-]{1,512}$", name))])
    error_message = "Supply exact log group names, never wildcards, ARNs, or stream suffixes."
  }
}
