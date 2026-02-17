variable "name" {
  description = "Name for the Grafana workspace"
  type        = string
}

variable "authentication_providers" {
  description = "Authentication providers (AWS_SSO or SAML)"
  type        = list(string)
  default     = ["AWS_SSO"]

  validation {
    condition = alltrue([
      for p in var.authentication_providers : contains(["AWS_SSO", "SAML"], p)
    ])
    error_message = "authentication_providers must be AWS_SSO or SAML."
  }
}

variable "amp_workspace_id" {
  description = "AMP workspace ID to configure as datasource"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}