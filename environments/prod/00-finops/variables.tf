variable "billing_access" {
  description = "Local billing profile or existing management-account role; null fields use the current credentials, whose account is still validated."
  type        = object({ profile = optional(string), role_arn = optional(string) })
  default     = {}
  nullable    = false
  validation {
    condition = !(var.billing_access.profile != null && var.billing_access.role_arn != null) && (
      var.billing_access.profile == null ? true : length(trimspace(var.billing_access.profile)) > 0
      ) && (
      var.billing_access.role_arn == null ? true : can(regex("^arn:aws:iam::[0-9]{12}:role/[^*?]+$", var.billing_access.role_arn))
    )
    error_message = "Select at most one nonempty billing profile or concrete management-account role, never both."
  }
}
variable "billing_account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.billing_account_id))
    error_message = "Supply the actual Organizations management account ID."
  }
}
variable "workload_account_id" {
  type = string
  validation {
    condition     = can(regex("^[0-9]{12}$", var.workload_account_id))
    error_message = "Supply the production workload account ID."
  }
}
variable "aws_region" {
  type = string
  validation {
    condition     = contains(["us-east-1", "ap-northeast-2"], var.aws_region)
    error_message = "Select the workload Region independently of billing us-east-1."
  }
}
variable "project_name" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,49}$", var.project_name))
    error_message = "Use a canonical lowercase platform project name."
  }
}
variable "platform_instance_id" { type = string }
variable "owner" {
  type     = string
  nullable = false
  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "A nonempty production cost owner is required."
  }
}
variable "cost_center" { type = string }
variable "finops" {
  type = object({ monthly_budget_usd = number, anomaly_threshold_usd = number, notification_topic_arn = string })
}
