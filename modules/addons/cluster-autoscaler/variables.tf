variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster's OIDC Provider"
  type        = string
}

variable "oidc_provider" {
  description = "OIDC provider URL without https:// prefix"
  type        = string
}

variable "aws_region" {
  description = "AWS Region"
  type        = string
}

variable "chart_version" {
  description = "Helm chart version for cluster-autoscaler"
  type        = string
  default     = "9.59.0"
}

variable "tags" {
  description = "Map of tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "common_tags" {
  description = "DEPRECATED: Use 'tags' instead. Map of common tags."
  type        = map(string)
  default     = null
}

locals {
  effective_tags = var.common_tags != null ? var.common_tags : var.tags
}
variable "environment" {
  type = string
}
variable "autoscaling_mode" {
  type = string
  validation {
    condition     = contains(["fixed", "mng_cluster_autoscaler"], var.autoscaling_mode) && (var.environment != "prod" || var.autoscaling_mode == "mng_cluster_autoscaler")
    error_message = "Production requires managed nodes with Cluster Autoscaler."
  }
}
variable "autoscaler_capacity" {
  type = object({
    min_nodes                    = number
    max_nodes                    = number
    max_pods_per_node            = number
    hpa_max_replicas             = number
    rollout_surge_replicas       = number
    platform_reserve_pods        = number
    stable_replicas              = number
    canary_replicas              = number
    usable_subnet_ips_by_az      = map(number)
    required_headroom_percentage = number
  })
  validation {
    condition = (
      var.autoscaler_capacity.min_nodes >= 1 &&
      var.autoscaler_capacity.max_nodes >= var.autoscaler_capacity.min_nodes &&
      var.autoscaler_capacity.max_pods_per_node >= 1 &&
      alltrue([for n in [var.autoscaler_capacity.hpa_max_replicas, var.autoscaler_capacity.rollout_surge_replicas, var.autoscaler_capacity.platform_reserve_pods, var.autoscaler_capacity.stable_replicas, var.autoscaler_capacity.canary_replicas] : n >= 0 && floor(n) == n]) &&
      var.autoscaler_capacity.required_headroom_percentage >= 10 &&
      var.autoscaler_capacity.required_headroom_percentage <= 100 &&
      (max(var.autoscaler_capacity.hpa_max_replicas, var.autoscaler_capacity.stable_replicas + var.autoscaler_capacity.canary_replicas) + var.autoscaler_capacity.rollout_surge_replicas + var.autoscaler_capacity.platform_reserve_pods) * (1 + var.autoscaler_capacity.required_headroom_percentage / 100) <= var.autoscaler_capacity.max_nodes * var.autoscaler_capacity.max_pods_per_node &&
      length(var.autoscaler_capacity.usable_subnet_ips_by_az) >= (var.environment == "prod" ? 3 : 2) &&
      alltrue([for ip in values(var.autoscaler_capacity.usable_subnet_ips_by_az) : ip >= ceil(var.autoscaler_capacity.max_nodes / max(length(var.autoscaler_capacity.usable_subnet_ips_by_az), 1)) * var.autoscaler_capacity.max_pods_per_node * (1 + var.autoscaler_capacity.required_headroom_percentage / 100)])
    )
    error_message = "Node/pod capacity and every AZ IP pool must cover workload, surge, reserve and headroom."
  }
}
