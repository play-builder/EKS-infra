variable "name" {
  description = "Name/alias for the AMP workspace"
  type        = string
}

variable "retention_days" {
  description = "Metrics retention period in days (default 90, max 150)"
  type        = number
  default     = 90

  validation {
    condition     = var.retention_days >= 1 && var.retention_days <= 150
    error_message = "retention_days must be between 1 and 150."
  }
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}