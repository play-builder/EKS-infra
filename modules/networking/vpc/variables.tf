
variable "name" {
  description = "Name prefix for resources"
  type        = string
}

variable "environment" {
  description = "Environment that owns this VPC"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
}

variable "availability_zones" {
  description = "List of availability zones"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "Public subnet CIDR blocks"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "Private subnet CIDR blocks"
  type        = list(string)
}

variable "database_subnet_cidrs" {
  description = "Database subnet CIDR blocks"
  type        = list(string)
  default     = []
}

variable "enable_nat_gateway" {
  description = "Enable NAT Gateway"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use single NAT Gateway"
  type        = bool
  default     = false
}

variable "one_nat_gateway_per_az" {
  description = "One NAT Gateway per AZ"
  type        = bool
  default     = false
}

variable "production_nat_topology" {
  description = "Production egress topology: regional or per_az"
  type        = string
  default     = "regional"

  validation {
    condition     = contains(["regional", "per_az"], var.production_nat_topology)
    error_message = "production_nat_topology must be regional or per_az."
  }

  validation {
    condition = var.environment != "prod" || (
      var.production_nat_topology == "per_az" &&
      var.enable_nat_gateway &&
      !var.single_nat_gateway &&
      var.one_nat_gateway_per_az
    )
    error_message = "Production VPCs require per_az NAT topology with NAT enabled, no single NAT, and one NAT gateway per AZ."
  }
}

variable "enable_vpc_flow_logs" {
  description = "Send all VPC Flow Logs to a dedicated CloudWatch Logs group"
  type        = bool
  default     = false
}

variable "vpc_flow_log_retention_in_days" {
  description = "Retention period for VPC Flow Logs before Task 9 adds KMS protection"
  type        = number
  default     = 30

  validation {
    condition     = var.vpc_flow_log_retention_in_days >= 1
    error_message = "vpc_flow_log_retention_in_days must be at least one day."
  }
}

variable "vpc_flow_log_kms_key_arn" {
  description = "Optional KMS key ARN for the VPC Flow Log group"
  type        = string
  default     = null
  nullable    = true
}

variable "enable_dns_hostnames" {
  description = "Enable DNS hostnames"
  type        = bool
  default     = true
}

variable "enable_dns_support" {
  description = "Enable DNS support"
  type        = bool
  default     = true
}

variable "eks_cluster_name" {
  description = "EKS cluster name for subnet tagging"
  type        = string
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
