variable "cluster_name" { type = string }
variable "managed_addon_versions" {
  type = object({ coredns = string, kube_proxy = string })
  validation {
    condition     = alltrue([for v in values(var.managed_addon_versions) : can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+-eksbuild\\.[0-9]+$", v))])
    error_message = "Supply exact AWS-verified regional CoreDNS and kube-proxy pins."
  }
}
variable "tags" {
  type = map(string)
  validation {
    condition     = alltrue([for k in ["PlatformInstanceId", "Owner", "CostCenter", "Environment"] : try(trimspace(var.tags[k]) != "", false)])
    error_message = "Mandatory ownership tags are required."
  }
}
