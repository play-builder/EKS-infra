variable "required_repositories" {
  description = "Exact repositories that must be continuously scanned; no implicit prefix expansion."
  type        = set(string)
  validation {
    condition     = length(var.required_repositories) > 0 && alltrue([for r in var.required_repositories : can(regex("^[a-z0-9]+([._/-][a-z0-9]+)*$", r))])
    error_message = "At least one exact ECR repository name is required."
  }
}

variable "configuration" {
  type = object({
    ownership_mode                  = string
    scan_type                       = string
    scan_frequency                  = string
    repository_filters              = set(string)
    scan_on_push_repository_filters = optional(set(string), [])
  })
  validation {
    condition = (
      contains(["terraform", "external"], var.configuration.ownership_mode) &&
      var.configuration.scan_type == "ENHANCED" && var.configuration.scan_frequency == "CONTINUOUS_SCAN" &&
      (var.configuration.ownership_mode == "external" ||
      length(setsubtract(var.required_repositories, var.configuration.repository_filters)) == 0) &&
      alltrue([for f in setunion(var.configuration.repository_filters, var.configuration.scan_on_push_repository_filters) :
      length(f) > 0 && length(f) <= 255 && can(regex("^[a-z0-9_./*-]+$", f))])
    )
    error_message = "Require ENHANCED/CONTINUOUS_SCAN. Terraform ownership must explicitly include every required exact repository and preserve all other reviewed registry filters."
  }
}

variable "ownership_handoff" {
  description = "Reviewed account/region singleton ownership transfer; not proof of live scanning. The prior owner must release state ownership without deleting the remote singleton."
  type = object({
    account_id         = string
    aws_region         = string
    approval_reference = string
  })
  default = null
  validation {
    condition = var.ownership_handoff == null ? var.configuration.ownership_mode == "external" : (
      can(regex("^[0-9]{12}$", var.ownership_handoff.account_id)) &&
      length(trimspace(var.ownership_handoff.approval_reference)) >= 8
    )
    error_message = "Terraform scanning ownership requires an explicit reviewed handoff with account ID, region and change reference."
  }
}
