
variable "name" {
  description = "Common name prefix (e.g., 'dev-playdevops')"
  type        = string
}

variable "eks_cluster_name" {
  description = "EKS Cluster name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "oidc_provider_arn" {
  description = "OIDC Provider ARN for IRSA"
  type        = string
}

variable "oidc_provider" {
  description = "OIDC Provider URL (without https://)"
  type        = string
}

variable "aws_region" {
  description = "AWS Region"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace to install the controller"
  type        = string
  default     = "kube-system"
}

variable "service_account_name" {
  description = "Kubernetes Service Account name"
  type        = string
  default     = "aws-load-balancer-controller"
}

variable "helm_chart_version" {
  description = "AWS Load Balancer Controller Helm chart version"
  type        = string
  default     = "1.14.5"
}

variable "ecr_account_id" {
  description = "ECR Account ID for AWS Load Balancer Controller image"
  type        = string
  default     = "602401143452"
}

variable "replica_count" {
  description = "Number of replicas for the controller"
  type        = number
  default     = 2

  validation {
    condition     = var.replica_count >= 1 && var.replica_count <= 5
    error_message = "replica_count must be between 1 and 5."
  }
}

variable "ingress_class_name" {
  description = "Name of the IngressClass"
  type        = string
  default     = "alb"
}

variable "is_default_class" {
  description = "Set this IngressClass as default"
  type        = bool
  default     = true
}

variable "enable_waf" {
  description = "Enable AWS WAF integration"
  type        = bool
  default     = false
}

variable "enable_wafv2" {
  description = "Enable AWS WAFv2 integration"
  type        = bool
  default     = true
}

variable "enable_shield" {
  description = "Enable AWS Shield integration"
  type        = bool
  default     = false
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