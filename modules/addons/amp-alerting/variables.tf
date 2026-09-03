variable "enabled" {
  description = "Enable Ch16 AMP recording rules and Alertmanager"
  type        = bool
  default     = false
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
  description = "Selected course Region used by Alertmanager SigV4"
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
