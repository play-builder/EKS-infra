# ============================================
# EBS CSI Driver Add-on Module Variables
# ============================================

variable "name" {
  description = "Name prefix for resources"
  type        = string
}

variable "eks_cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "oidc_provider_arn" {
  description = "OIDC provider ARN from EKS cluster"
  type        = string
}

variable "oidc_provider" {
  description = "OIDC provider URL (without https://)"
  type        = string
}

variable "addon_version" {
  description = "EBS CSI Driver add-on version (leave empty for latest)"
  type        = string
  default     = ""
}

variable "resolve_conflicts_on_create" {
  description = "How to resolve conflicts (OVERWRITE or NONE)"
  type        = string
  default     = "OVERWRITE"

  validation {
    condition     = contains(["OVERWRITE", "NONE"], var.resolve_conflicts_on_create)
    error_message = "resolve_conflicts_on_create must be either OVERWRITE or NONE"
  }
}

variable "service_account_name" {
  description = "Kubernetes Service Account name for EBS CSI Controller"
  type        = string
  default     = "ebs-csi-controller-sa"
}

variable "namespace" {
  description = "Kubernetes namespace for EBS CSI Driver"
  type        = string
  default     = "kube-system"
}

variable "use_aws_managed_policy" {
  description = "Use AWS managed IAM policy instead of custom policy"
  type        = bool
  default     = false
}

variable "aws_managed_policy_arn" {
  description = "AWS managed IAM policy ARN for EBS CSI Driver"
  type        = string
  default     = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

variable "tags" {
  description = "Additional tags for IAM resources"
  type        = map(string)
  default     = {}
}