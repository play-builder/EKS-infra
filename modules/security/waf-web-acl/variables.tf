variable "name" {
  type = string
  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,100}$", var.name))
    error_message = "name must be a safe WAF and metric identifier."
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

variable "kms_key_arn" {
  type = string
  validation {
    condition     = can(regex("^arn:aws:kms:${var.aws_region}:${var.account_id}:key/[0-9a-f-]{36}$", var.kms_key_arn))
    error_message = "WAF logs require an exact same-account and same-Region KMS key ARN."
  }
}
variable "retention_days" {
  type = number
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.retention_days) && (var.environment != "prod" || var.retention_days >= 90)
    error_message = "Use a supported finite CloudWatch retention; prod requires at least 90 days."
  }
}
variable "rate_limit" {
  description = "Maximum requests per source IP in a five-minute evaluation window."
  type        = number
  default     = 2000
  validation {
    condition     = var.rate_limit == floor(var.rate_limit) && var.rate_limit >= 10 && var.rate_limit <= 100000
    error_message = "rate_limit must be an integer from 10 to 100000."
  }
}
