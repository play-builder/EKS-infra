variable "enable_k6_operator" {
  description = "Enable the Ch16-only k6 operator"
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_k6_operator || var.environment == "dev"
    error_message = "K6_OPERATOR_DEV_ONLY: the course load controller may be enabled only in dev."
  }
}

variable "environment" {
  description = "Course environment"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "chart_version" {
  description = "Pinned Grafana k6 operator Helm chart version"
  type        = string
  default     = "4.6.0"
}

variable "namespace" {
  description = "Dedicated controller namespace; never an application namespace"
  type        = string
  default     = "k6-operator-system"

  validation {
    condition     = !startswith(var.namespace, "app-") && var.namespace != "prod"
    error_message = "k6 operator must use a dedicated non-application namespace."
  }
}
