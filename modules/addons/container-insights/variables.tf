variable "eks_cluster_name" {
  type = string
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,99}$", var.eks_cluster_name))
    error_message = "Use a valid EKS cluster name."
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
variable "kms_key_arn" {
  type = string
  validation {
    condition     = can(regex("^arn:aws:kms:${var.aws_region}:${var.account_id}:key/[0-9a-f-]{36}$", var.kms_key_arn))
    error_message = "Logs require an exact same-account and same-Region KMS key ARN."
  }
}
variable "application_retention_days" {
  type    = number
  default = 90
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.application_retention_days) && (var.environment != "prod" || var.application_retention_days >= 90)
    error_message = "Application logs require valid finite retention and at least 90 days in prod."
  }
}
variable "performance_retention_days" {
  type    = number
  default = 90
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.performance_retention_days) && (var.environment != "prod" || var.performance_retention_days >= 90)
    error_message = "Performance logs require valid finite retention and at least 90 days in prod."
  }
}
variable "oidc_provider_arn" {
  type = string
  validation {
    condition     = var.oidc_provider_arn == "arn:aws:iam::${var.account_id}:oidc-provider/${var.oidc_provider}"
    error_message = "OIDC ARN must match the exact issuer and workload account."
  }
}
variable "oidc_provider" {
  type = string
  validation {
    condition     = can(regex("^oidc.eks.${var.aws_region}.amazonaws.com/id/[A-Za-z0-9]+$", var.oidc_provider))
    error_message = "Use the regional EKS OIDC issuer without https://."
  }
}
variable "cloudwatch_agent_chart_version" {
  description = "Pinned chart; its kubernetes collector emits the performance group."
  type        = string
  default     = "0.0.9"
}
variable "fluent_bit_chart_version" {
  type    = string
  default = "0.1.32"
}
variable "tags" {
  type = map(string)
  validation {
    condition     = alltrue([for k in ["PlatformInstanceId", "Owner", "CostCenter", "Environment"] : try(trimspace(var.tags[k]) != "", false)]) && try(var.tags.Environment == var.environment, false)
    error_message = "Required nonempty platform tags must include the matching Environment."
  }
}
