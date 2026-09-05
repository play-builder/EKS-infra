
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
  description = "Retention period for VPC Flow Logs"
  type        = number
  default     = 30

  validation {
    condition     = !var.enable_vpc_flow_logs || (contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.vpc_flow_log_retention_in_days) && (var.environment != "prod" || var.vpc_flow_log_retention_in_days >= 90))
    error_message = "Enabled Flow Logs require valid finite retention; prod requires at least 90 days."
  }
}

variable "vpc_flow_log_kms_key_arn" {
  description = "Customer-managed KMS key ARN for the VPC Flow Log group"
  type        = string
  default     = null
  nullable    = true
  validation {
    condition     = !var.enable_vpc_flow_logs || var.environment != "prod" || can(regex("^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-f-]{36}$", var.vpc_flow_log_kms_key_arn))
    error_message = "Production Flow Logs require an exact customer-managed KMS key ARN."
  }
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

  validation {
    condition = var.environment != "prod" || alltrue([
      for key in ["PlatformInstanceId", "Owner", "CostCenter", "Environment"] :
      try(length(trimspace(var.tags[key])) > 0, false)
    ])
    error_message = "PLATFORM_TAGS_REQUIRED: production VPC resources require nonblank PlatformInstanceId, Owner, CostCenter, and Environment tags."
  }
}
