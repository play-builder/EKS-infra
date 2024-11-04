# ============================================
# AWS Load Balancer Controller Variables
# ============================================

# ============================================
# Required Variables
# ============================================
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

# ============================================
# Kubernetes Config Variables 
# ============================================
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

# ============================================
# Optional Variables
# ============================================
variable "helm_chart_version" {
  description = "AWS Load Balancer Controller Helm chart version"
  type        = string
  default     = "1.14.5" # 최신 버전으로 업데이트 가능
}

variable "ecr_account_id" {
  description = "ECR Account ID for AWS Load Balancer Controller image"
  type        = string
  default     = "602401143452" # us-east-1 기본값
  # Region별 Account ID:
  # us-east-1: 602401143452
  # us-west-2: 602401143452
  # eu-west-1: 602401143452
  # ap-northeast-1: 602401143452
  # 기타 Region: https://docs.aws.amazon.com/eks/latest/userguide/add-ons-images.html
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

# ============================================
# Feature Flags
# ============================================
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

# ============================================
# Tags
# ============================================
variable "common_tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default     = {}
}