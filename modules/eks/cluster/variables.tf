
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
  default     = "1.36"

  validation {
    condition     = can(regex("^1\\.(3[0-9])$", var.cluster_version))
    error_message = "cluster_version must be 1.30 or higher. Versions below 1.30 are EOL."
  }
}

variable "authentication_mode" {
  description = "EKS authentication mode. This course uses Access Entry API instead of aws-auth."
  type        = string
  default     = "API"

  validation {
    condition     = contains(["API", "API_AND_CONFIG_MAP"], var.authentication_mode)
    error_message = "authentication_mode must be API or API_AND_CONFIG_MAP."
  }
}

variable "bootstrap_cluster_creator_admin_permissions" {
  description = "Grant the creating principal automatic cluster-admin permissions"
  type        = bool
  default     = false
  validation {
    condition     = !var.bootstrap_cluster_creator_admin_permissions
    error_message = "Use the named typed break-glass Access Entry; automatic creator admin is disabled."
  }
}

variable "cluster_admin_principal_arns" {
  description = "Explicit IAM principals granted AmazonEKSClusterAdminPolicy through Access Entries"
  type        = set(string)
  default     = []

  validation {
    condition     = length(var.cluster_admin_principal_arns) == 0
    error_message = "Migrate legacy principal state to the access-entries module."
  }
}

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

  validation {
    condition = !var.cluster_endpoint_public_access || (
      length(var.cluster_endpoint_public_access_cidrs) > 0 && alltrue([
        for cidr in var.cluster_endpoint_public_access_cidrs :
        can(cidrhost(cidr, 0)) && cidr != "0.0.0.0/0"
      ])
    )
    error_message = "Public endpoint access requires at least one valid restricted CIDR; 0.0.0.0/0 is not allowed."
  }
}


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
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.cluster_log_retention_in_days) && (var.environment != "prod" || var.cluster_log_retention_in_days >= 90)
    error_message = "cluster_log_retention_in_days must be a valid CloudWatch Logs retention period."
  }
}

variable "vpc_cni_addon_version" {
  description = "EKS-compatible VPC CNI add-on version verified in both course Regions"
  type        = string

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+-eksbuild\\.[0-9]+$", var.vpc_cni_addon_version))
    error_message = "vpc_cni_addon_version must use the EKS add-on version form."
  }
}

variable "vpc_cni_enable_network_policy" {
  description = "Enable VPC CNI NetworkPolicy support"
  type        = bool
  default     = false
}

variable "vpc_cni_network_policy_enforcing_mode" {
  description = "VPC CNI policy mode; strict requires current approval evidence"
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "strict"], var.vpc_cni_network_policy_enforcing_mode)
    error_message = "VPC CNI enforcing mode must be standard or strict."
  }
}

variable "vpc_cni_strict_gate_evidence_file" {
  description = "Current course.network-policy-strict-gate/v1 record required for strict mode"
  type        = string
  default     = null
  nullable    = true
}

variable "tags" {
  description = "Map of tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "enable_cluster_creator_access" {
  description = "Enable Access Entry for cluster creator (for initial kubectl access)"
  type        = bool
  default     = false
  validation {
    condition     = !var.enable_cluster_creator_access
    error_message = "Use the typed access-entries module."
  }
}

variable "cluster_creator_arn" {
  description = "IAM ARN of the cluster creator (user or role) for Access Entry"
  type        = string
  default     = ""
}
variable "environment" {
  type    = string
  default = "dev"
}
variable "cluster_log_kms_key_arn" {
  type    = string
  default = null
  validation {
    condition     = var.environment != "prod" || try(can(regex("^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-f-]{36}$", var.cluster_log_kms_key_arn)), false)
    error_message = "Production audit logs require a customer-managed KMS key ARN."
  }
}
