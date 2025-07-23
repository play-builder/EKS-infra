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
  default     = "9.37.0"
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