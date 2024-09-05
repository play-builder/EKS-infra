# ============================================
# EKS Node Group Module - Variables
# ============================================

# ============================================
# Required Variables (클러스터 정보)
# ============================================
variable "cluster_name" {
  description = "Name of the EKS cluster (from cluster module output)"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version of the cluster (for node version sync)"
  type        = string
}

variable "name" {
  description = "Common name prefix (e.g., 'dev-playdevops')"
  type        = string
}

variable "node_group_name" {
  description = "Name of the EKS Node Group (e.g., 'public-nodes', 'private-nodes', 'compute-optimized')"
  type        = string
}

variable "subnet_ids" {
  description = "List of Subnet IDs where nodes will be deployed (public or private subnets)"
  type        = list(string)
}

variable "node_group_type" {
  description = "Type of node group (public or private) - used for tagging"
  type        = string
  default     = "private"

  validation {
    condition     = contains(["public", "private"], var.node_group_type)
    error_message = "node_group_type must be either 'public' or 'private'."
  }
}

# ============================================
# Scaling Configuration
# ============================================
variable "desired_size" {
  description = "Desired number of nodes (managed by Cluster Autoscaler)"
  type        = number
  default     = 2
}

variable "min_size" {
  description = "Minimum number of nodes"
  type        = number
  default     = 1

  validation {
    condition     = var.min_size >= 1
    error_message = "min_size must be at least 1."
  }
}

variable "max_size" {
  description = "Maximum number of nodes"
  type        = number
  default     = 5

  validation {
    condition     = var.max_size >= var.min_size
    error_message = "max_size must be greater than or equal to min_size."
  }
}

# ============================================
# Instance Configuration
# ============================================
variable "instance_types" {
  description = "List of EC2 instance types for the nodes"
  type        = list(string)
  default     = ["t3.medium"]
}

variable "capacity_type" {
  description = "Capacity type (ON_DEMAND or SPOT)"
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.capacity_type)
    error_message = "capacity_type must be either 'ON_DEMAND' or 'SPOT'."
  }
}

variable "ami_type" {
  description = "AMI type for EKS nodes"
  type        = string
  default     = "AL2_x86_64"

  validation {
    condition = contains([
      "AL2_x86_64",
      "AL2023_ARM_64_STANDARD",
      "AL2_x86_64",
      "AL2_x86_64_GPU",
      "AL2_ARM_64"
    ], var.ami_type)
    error_message = "Invalid AMI type. See AWS EKS documentation for valid values."
  }
}

variable "disk_size" {
  description = "EBS root volume size (in GB)"
  type        = number
  default     = 20

  validation {
    condition     = var.disk_size >= 20 && var.disk_size <= 1000
    error_message = "disk_size must be between 20 and 1000 GB."
  }
}

# ============================================
# Update Configuration
# ============================================
variable "max_unavailable_percentage" {
  description = "Max unavailable nodes percentage during rolling updates"
  type        = number
  default     = 33 # 33%

  validation {
    condition     = var.max_unavailable_percentage > 0 && var.max_unavailable_percentage <= 100
    error_message = "max_unavailable_percentage must be between 1 and 100."
  }
}

# ============================================
# SSH Access Configuration
# ============================================
variable "ssh_key_name" {
  description = "EC2 Key Pair name for SSH access to nodes (leave empty to disable SSH)"
  type        = string
  default     = ""
}

variable "ssh_source_security_group_ids" {
  description = "List of security group IDs allowed to SSH (e.g., Bastion SG)"
  type        = list(string)
  default     = []
}

# ============================================
# Feature Flags
# ============================================
variable "enable_ssm" {
  description = "Enable AWS Systems Manager (SSM) access for debugging"
  type        = bool
  default     = true
}

variable "enable_cloudwatch" {
  description = "Enable CloudWatch Container Insights"
  type        = bool
  default     = true
}

# ============================================
# Kubernetes Labels
# ============================================
variable "kubernetes_labels" {
  description = "Map of Kubernetes labels to apply to the nodes"
  type        = map(string)
  default     = {}
}

# ============================================
# Tags
# ============================================
variable "common_tags" {
  description = "Map of common tags to apply to all resources"
  type        = map(string)
  default     = {}
}