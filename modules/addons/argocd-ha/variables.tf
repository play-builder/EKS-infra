variable "name" { type = string }
variable "environment" { type = string }
variable "region" { type = string }
variable "oidc_provider_arn" { type = string }
variable "oidc_provider" { type = string }
variable "tags" {
  type = map(string)
  validation {
    condition     = alltrue([for k in ["PlatformInstanceId", "Owner", "CostCenter", "Environment"] : try(trimspace(var.tags[k]) != "", false)])
    error_message = "Mandatory ownership tags are required."
  }
}
variable "health_customizations" { type = map(string) }
variable "platform" {
  type = object({ server_replicas = number, repo_server_replicas = number, controller_replicas = number, applicationset_replicas = number, redis_ha = bool, node_count = number, az_count = number, public_url = string, oidc_issuer_url = string, oidc_client_id = string, admin_group = string, readonly_group = string })
  validation {
    condition     = (var.environment != "prod" || (var.platform.redis_ha && var.platform.node_count >= 3 && var.platform.az_count >= 3 && min(var.platform.server_replicas, var.platform.repo_server_replicas, var.platform.controller_replicas, var.platform.applicationset_replicas) >= 2)) && min(var.platform.server_replicas, var.platform.repo_server_replicas, var.platform.controller_replicas, var.platform.applicationset_replicas) >= 1 && can(regex("^https://[^ ]+$", var.platform.oidc_issuer_url)) && trimspace(var.platform.oidc_client_id) != "" && alltrue([for g in [var.platform.admin_group, var.platform.readonly_group] : can(regex("^[A-Za-z0-9_:@./-]+$", g))]) && var.platform.admin_group != var.platform.readonly_group
    error_message = "Prod requires four HA controllers, Redis HA, 3 nodes/AZs and valid distinct native OIDC groups."
  }
}
