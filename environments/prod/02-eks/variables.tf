
variable "aws_region" {
  description = "AWS Region"
  type        = string

  validation {
    condition     = contains(["ap-northeast-2", "us-east-1"], var.aws_region)
    error_message = "aws_region must be ap-northeast-2 or us-east-1."
  }
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "playdevops"
}

variable "state_bucket_name" {
  description = "Exact S3 bucket name that stores this environment's Terraform states"
  type        = string
}

variable "course_id" {
  description = "Unique CourseId binding all course-owned resources and cleanup evidence"
  type        = string
  default     = "course-2026"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{7,62}$", var.course_id))
    error_message = "course_id must be a unique 8-63 character lowercase identifier."
  }
}

variable "division" {
  description = "Organizational or technical division responsible for this infrastructure"
  type        = string
  default     = "CloudInfra"
}

variable "cluster_name" {
  description = "EKS Cluster name"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version to use for the EKS cluster"
  type        = string
  default     = "1.36"
}

variable "authentication_mode" {
  description = "EKS authentication mode"
  type        = string
  default     = "API"
}

variable "bootstrap_cluster_creator_admin_permissions" {
  description = "Automatically grant cluster admin to the Terraform caller"
  type        = bool
  default     = false
}

variable "cluster_admin_principal_arns" {
  description = "Explicit IAM principals granted cluster-admin through Access Entries"
  type        = set(string)
  default     = []
}

variable "cluster_service_ipv4_cidr" {
  description = "Service IPv4 CIDR for the cluster"
  type        = string
  default     = "172.20.0.0/16"
}

variable "cluster_endpoint_private_access" {
  description = "Enable private API server endpoint"
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access" {
  description = "Enable public API server endpoint"
  type        = bool
  default     = false
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "List of CIDR blocks for public access"
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

variable "enable_public_node_group" {
  description = "Enable Public Node Group (NOT recommended for Production)"
  type        = bool
  default     = false
}

variable "enable_private_node_group" {
  description = "Enable Private Node Group (Recommended for Production)"
  type        = bool
  default     = true
}

variable "node_group_ami_type" {
  description = "AMI type for EKS nodes"
  type        = string
  default     = "AL2023_x86_64_STANDARD"
}

variable "node_group_capacity_type" {
  description = "Capacity type (ON_DEMAND or SPOT)"
  type        = string
  default     = "ON_DEMAND"
}

variable "node_group_disk_size" {
  description = "Disk size in GiB for worker nodes"
  type        = number
  default     = 50
}

variable "node_group_max_unavailable" {
  description = "Max unavailable nodes percentage during update"
  type        = number
  default     = 33
}

variable "private_node_group_name" {
  description = "Private node group name"
  type        = string
  default     = "private-nodes"
}

variable "private_node_group_desired_size" {
  description = "Private node group desired size"
  type        = number
  default     = 3
}

variable "private_node_group_min_size" {
  description = "Private node group min size"
  type        = number
  default     = 2
}

variable "private_node_group_max_size" {
  description = "Private node group max size"
  type        = number
  default     = 5
}

variable "private_node_group_instance_types" {
  description = "Private node group instance types"
  type        = list(string)
  default     = ["m5.large"]
}

variable "enable_bastion" {
  description = "Enable Bastion Host"
  type        = bool
  default     = true
}

variable "bastion_instance_type" {
  description = "EC2 instance type for Bastion Host"
  type        = string
  default     = "t3.micro"
}

variable "bastion_instance_keypair" {
  description = "EC2 Key Pair name for Bastion Host"
  type        = string
}

variable "bastion_ssh_cidr_blocks" {
  description = "CIDR blocks allowed to SSH to Bastion"
  type        = list(string)
  default     = []
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
}

variable "cluster_log_retention_in_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 30
}

variable "vpc_cni_addon_version" {
  description = "VPC CNI add-on version resolved for EKS 1.36 in the selected Region"
  type        = string
}

variable "vpc_cni_enable_network_policy" {
  description = "False in Ch03; changed to true in Ch14"
  type        = bool
  default     = false
}

variable "vpc_cni_network_policy_enforcing_mode" {
  description = "Start with standard; strict requires a separate approved gate"
  type        = string
  default     = "standard"

  validation {
    condition     = contains(["standard", "strict"], var.vpc_cni_network_policy_enforcing_mode)
    error_message = "vpc_cni_network_policy_enforcing_mode must be standard or strict."
  }
}

variable "vpc_cni_strict_gate_evidence_file" {
  description = "Strict-mode approval evidence; null for standard mode"
  type        = string
  default     = null
  nullable    = true
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
