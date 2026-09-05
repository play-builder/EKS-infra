variable "required_repositories" { type = set(string) }
variable "configuration" {
  type = object({ ownership_mode = string, scan_type = string, scan_frequency = string, repository_filters = set(string) })
  validation {
    condition     = contains(["terraform", "external"], var.configuration.ownership_mode) && var.configuration.scan_type == "ENHANCED" && var.configuration.scan_frequency == "CONTINUOUS_SCAN" && toset(var.configuration.repository_filters) == toset([for r in var.required_repositories : "${r}*"])
    error_message = "Require ENHANCED/CONTINUOUS_SCAN and exact old/new migration prefixes."
  }
}
