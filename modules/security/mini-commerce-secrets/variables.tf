variable "name" { type = string }
variable "namespace" { type = string }
variable "region" { type = string }
variable "oidc_provider" { type = string }
variable "oidc_provider_arn" { type = string }
variable "tags" {
  type = map(string)
  validation {
    condition     = alltrue([for k in ["PlatformInstanceId", "Owner", "CostCenter", "Environment"] : try(trimspace(var.tags[k]) != "", false)])
    error_message = "Mandatory ownership tags required."
  }
}
