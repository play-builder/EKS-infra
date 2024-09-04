# ============================================
# EKS Cluster Module - Variables
# ============================================
# 리팩토링: Node Group 변수 모두 제거, Cluster 관련 변수만 유지

# ============================================
# General Variables
# ============================================
variable "name" {
  description = "Common name prefix (e.g., 'dev-playdevops')"
  type        = string
}

variable "cluster_name" {
  description = "EKS Cluster name"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version to use for the EKS cluster"
  type        = string
  default     = "1.31"

  validation {
    condition     = can(regex("^1\\.(2[7-9]|3[0-9])$", var.cluster_version))
    error_message = "cluster_version must be a valid Kubernetes version (1.27 or higher)."
  }
}

# ============================================
# Network Configuration
# ============================================
variable "vpc_id" {
  description = "VPC ID where the cluster will be created"
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs for the cluster"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for the cluster"
  type        = list(string)
}

# ============================================
# Cluster Configuration
# ============================================
variable "cluster_service_ipv4_cidr" {
  description = "Service IPv4 CIDR for the cluster (do not overlap with VPC CIDR)"
  type        = string
  default     = "172.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.cluster_service_ipv4_cidr, 0))
    error_message = "cluster_service_ipv4_cidr must be a valid IPv4 CIDR block."
  }
}

variable "cluster_endpoint_private_access" {
  description = "Enable private API server endpoint"
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access" {
  description = "Enable public API server endpoint"
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "List of CIDR blocks allowed to access the public API server endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"] # ⚠️ Production에서는 제한 필요 
  # default     = []  # ✅ 기본값 비움 (Private access만 사용) [PROD] dev.tfvars 등에서 회사의 VPN IP나 NAT Gateway IP 등 신뢰할 수 있는 CIDR만 허용하도록 강제해야 합니다.

  validation {
    condition = alltrue([
      for cidr in var.cluster_endpoint_public_access_cidrs : can(cidrhost(cidr, 0))
    ])
    error_message = "All CIDR blocks must be valid IPv4 CIDR notation."
  }
}

# ============================================
# OIDC Provider Configuration
# ============================================
# variable "eks_oidc_root_ca_thumbprint" {
#   description = "Thumbprint of Root CA for EKS OIDC (required for IRSA)"
#   type        = string
#   default     = "9e99a48a9960b14926bb7f3b02e22da2b0ab7280" # AWS Global thumbprint
# }

# ============================================
# Logging Configuration
# ============================================
variable "cluster_enabled_log_types" {
  description = "List of control plane logging types to enable"
  type        = list(string)
  default = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler"
  ]

  validation {
    condition = alltrue([
      for log_type in var.cluster_enabled_log_types :
      contains(["api", "audit", "authenticator", "controllerManager", "scheduler"], log_type)
    ])
    error_message = "cluster_enabled_log_types can only contain: api, audit, authenticator, controllerManager, scheduler."
  }
}

variable "cluster_log_retention_in_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 7

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.cluster_log_retention_in_days)
    error_message = "cluster_log_retention_in_days must be a valid CloudWatch Logs retention period."
  }
}

# ============================================
# Tags
# ============================================
variable "tags" {
  description = "Map of tags to apply to all resources"
  type        = map(string)
  default     = {}
}