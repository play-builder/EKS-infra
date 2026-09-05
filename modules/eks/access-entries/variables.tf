variable "cluster_name" { type = string }
variable "tags" {
  type = map(string)
  validation {
    condition     = alltrue([for k in ["PlatformInstanceId", "Owner", "CostCenter", "Environment"] : try(trimspace(var.tags[k]) != "", false)])
    error_message = "Mandatory ownership tags are required."
  }
}
variable "access_entries" {
  type = map(object({ principal_arn = string, policy_arn = string, scope_type = string, namespaces = set(string), break_glass = bool }))
  validation {
    condition = length(distinct([for e in values(var.access_entries) : e.principal_arn])) == length(var.access_entries) && alltrue([
      for k, e in var.access_entries :
      contains(["platform-break-glass", "platform-operator", "release-automation", "developer-readonly"], k) &&
      can(regex("^arn:aws:iam::[0-9]{12}:role/[^*?]+$", e.principal_arn)) &&
      contains(["cluster", "namespace"], e.scope_type) &&
      (e.scope_type == "namespace" ? length(e.namespaces) > 0 && alltrue([for n in e.namespaces : can(regex("^[a-z0-9][a-z0-9-]*$", n))]) : length(e.namespaces) == 0) &&
      (k == "platform-break-glass" ? e.break_glass && e.scope_type == "cluster" && e.policy_arn == "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy" :
      !e.break_glass && e.scope_type == "namespace" && contains(k == "developer-readonly" ? ["arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"] : ["arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy", "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"], e.policy_arn))
    ])
    error_message = "Unique external IAM roles, named break-glass admin, and namespace-scoped operational privileges required."
  }
}
