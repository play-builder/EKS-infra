variable "name" {
  description = "Stable prefix for platform-owned billing resources."
  type        = string
  nullable    = false
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", var.name))
    error_message = "Use a stable alphanumeric billing resource prefix of at most 64 characters."
  }
}

variable "workload_region" {
  description = "Workload Region, independent of the billing provider Region."
  type        = string
  nullable    = false
  validation {
    condition     = contains(["us-east-1", "ap-northeast-2"], var.workload_region)
    error_message = "Workload Region must be us-east-1 or ap-northeast-2."
  }
}

variable "billing_account_id" {
  description = "Expected existing Organizations management account used by the billing provider."
  type        = string
  nullable    = false
  validation {
    condition     = can(regex("^[0-9]{12}$", var.billing_account_id))
    error_message = "An explicit 12-digit management billing account ID is required."
  }
}

variable "workload_account_id" {
  description = "Organization account whose tagged workload spend is covered by the budget."
  type        = string
  nullable    = false
  validation {
    condition     = can(regex("^[0-9]{12}$", var.workload_account_id))
    error_message = "An explicit 12-digit workload account ID is required."
  }
}

variable "finops" {
  description = "Platform cost objectives, ownership tags and independently owned billing SNS topic."
  type = object({
    monthly_budget_usd          = number
    alert_threshold_percentages = set(number)
    anomaly_threshold_usd       = number
    notification_topic_arn      = string
    required_tags               = map(string)
  })
  nullable = false
  validation {
    condition = (
      var.finops.monthly_budget_usd > 0 && var.finops.anomaly_threshold_usd > 0 &&
      var.finops.alert_threshold_percentages == toset([50, 80, 100])
    )
    error_message = "Budget and anomaly USD thresholds must be positive; actual budget notifications require 50, 80 and 100 percent."
  }
  validation {
    condition = (
      alltrue([for key in ["PlatformInstanceId", "Owner", "CostCenter", "Environment"] :
        try(length(trimspace(var.finops.required_tags[key])) > 0, false)
      ]) &&
      try(var.finops.required_tags.Environment == "prod", false) &&
      can(regex("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$", lookup(var.finops.required_tags, "PlatformInstanceId", "")))
    )
    error_message = "Nonempty platform ownership/cost tags and Environment=prod are required; PlatformInstanceId must be a canonical billing tag value."
  }
  validation {
    condition     = can(regex("^arn:aws:sns:us-east-1:[0-9]{12}:[A-Za-z0-9_-]{1,256}$", var.finops.notification_topic_arn))
    error_message = "Use an independently owned standard billing SNS topic ARN in us-east-1."
  }
}
