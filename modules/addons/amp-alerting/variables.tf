variable "enabled" {
  description = "Enable AMP recording rules and Alertmanager"
  type        = bool
  default     = false
}

variable "environment" {
  type    = string
  default = "dev"
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must identify app-dev or app-prod."
  }
}

variable "alert_owner" {
  type    = string
  default = "platform"
  validation {
    condition     = length(trimspace(var.alert_owner)) > 0
    error_message = "An alert owner is required."
  }
}

variable "runbook_url" {
  type    = string
  default = "https://github.com/play-builder/EKS-infra/blob/main/docs/runbooks/amp-slo.md"
  validation {
    condition     = can(regex("^https://[^ ]+$", var.runbook_url))
    error_message = "Use the actual HTTPS operator runbook URL."
  }
}

variable "slo" {
  type = object({
    success_target                = number
    latency_ms_target             = number
    short_window                  = string
    long_window                   = string
    short_burn_threshold          = number
    long_burn_threshold           = number
    traffic_floor_rps             = number
    paging_severity               = string
    escalation_route              = string
    alert_resolve_timeout_minutes = number
  })
  default = {
    success_target                = 0.999
    latency_ms_target             = 500
    short_window                  = "5m"
    long_window                   = "1h"
    short_burn_threshold          = 14.4
    long_burn_threshold           = 14.4
    traffic_floor_rps             = 0.1
    paging_severity               = "critical"
    escalation_route              = "platform-sns"
    alert_resolve_timeout_minutes = 15
  }
  validation {
    condition     = var.slo.success_target > 0 && var.slo.success_target < 1 && var.slo.latency_ms_target > 0 && var.slo.traffic_floor_rps > 0 && var.slo.short_burn_threshold > 0 && var.slo.long_burn_threshold > 0 && var.slo.alert_resolve_timeout_minutes > 0
    error_message = "SLO targets, burn thresholds, traffic floor and resolve timeout must be positive; success_target must be below one."
  }
  validation {
    condition     = can(regex("^[1-9][0-9]*[mh]$", var.slo.short_window)) && can(regex("^[1-9][0-9]*[mh]$", var.slo.long_window)) && try(tonumber(trimsuffix(trimsuffix(var.slo.short_window, "m"), "h")) * (endswith(var.slo.short_window, "h") ? 60 : 1) < tonumber(trimsuffix(trimsuffix(var.slo.long_window, "m"), "h")) * (endswith(var.slo.long_window, "h") ? 60 : 1), false)
    error_message = "Use positive minute/hour windows with short strictly below long."
  }
  validation {
    condition     = contains(["warning", "critical"], var.slo.paging_severity) && can(regex("^[a-z][a-z0-9-]+$", var.slo.escalation_route))
    error_message = "Use a bounded severity and an explicit receiver name."
  }
}

variable "workspace_id" {
  description = "AMP workspace ID"
  type        = string
}

variable "workspace_arn" {
  description = "Exact AMP workspace ARN allowed to publish to SNS"
  type        = string
}

variable "aws_region" {
  description = "Selected AWS Region used by Alertmanager SigV4"
  type        = string

  validation {
    condition     = contains(["ap-northeast-2", "us-east-1"], var.aws_region)
    error_message = "aws_region must be ap-northeast-2 or us-east-1."
  }
}

variable "enable_sns_delivery" {
  description = "Enable SNS delivery after an endpoint is explicitly supplied"
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_sns_delivery || (var.enabled && var.sns_email_endpoint != null)
    error_message = "SNS_DELIVERY_ENDPOINT_REQUIRED: enable_sns_delivery requires enabled=true and sns_email_endpoint."
  }
}

variable "sns_email_endpoint" {
  description = "Optional email endpoint; confirmation remains an external runtime step"
  type        = string
  default     = null
  nullable    = true
}

variable "name" {
  description = "Resource name prefix"
  type        = string
  default     = "course-dev"
}

variable "tags" {
  description = "Tags applied to SNS resources"
  type        = map(string)
  default     = {}
}
