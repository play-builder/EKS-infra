variable "aws_region" {
  description = "AWS Region for this environment"
  type        = string

  validation {
    condition     = contains(["ap-northeast-2", "us-east-1"], var.aws_region)
    error_message = "aws_region must be ap-northeast-2 or us-east-1."
  }
}

variable "project_name" {
  description = "Name of the project (e.g., playdevops)"
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

variable "platform_instance_id" {
  description = "Stable identifier shared by all resources in this platform instance"
  type        = string

  validation {
    condition     = length(trimspace(var.platform_instance_id)) > 0
    error_message = "platform_instance_id must not be blank."
  }
}

variable "owner" {
  description = "Team accountable for this production platform"
  type        = string

  validation {
    condition     = length(trimspace(var.owner)) > 0
    error_message = "owner must not be blank."
  }
}

variable "cost_center" {
  description = "Cost allocation identifier for this production platform"
  type        = string

  validation {
    condition     = length(trimspace(var.cost_center)) > 0
    error_message = "cost_center must not be blank."
  }
}

variable "environment" {
  description = "Name of the environment (e.g., prod)"
  type        = string
}

variable "division" {
  description = "Organizational or technical division responsible for this infrastructure"
  type        = string
  default     = "CloudInfra"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "availability_zones" {
  description = "Optional Availability Zone override; leave empty to use the first three standard AZs in aws_region"
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.availability_zones) == 0 || length(var.availability_zones) == 3
    error_message = "availability_zones must be empty for automatic selection or contain exactly three AZs."
  }
}

variable "public_subnet_cidrs" {
  description = "List of CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "List of CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

variable "database_subnet_cidrs" {
  description = "Database subnet CIDR blocks"
  type        = list(string)
  default     = ["10.0.21.0/24", "10.0.22.0/24", "10.0.23.0/24"]
}

variable "enable_nat_gateway" {
  description = "Enable NAT Gateway"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use single NAT Gateway for all AZs (false for HA in Production)"
  type        = bool
  default     = false
}

variable "one_nat_gateway_per_az" {
  description = "One NAT Gateway per AZ (true for HA in Production)"
  type        = bool
  default     = true
}

variable "production_nat_topology" {
  description = "Production NAT topology; resilient production egress requires per_az"
  type        = string
  default     = "per_az"

  validation {
    condition     = var.production_nat_topology == "per_az"
    error_message = "Production network must use production_nat_topology = per_az."
  }
}

variable "enable_vpc_flow_logs" {
  description = "Deliver all production VPC Flow Logs to CloudWatch Logs"
  type        = bool
  default     = true
}

variable "vpc_flow_log_retention_in_days" {
  description = "Retention for production VPC Flow Logs"
  type        = number
  default     = 30
}

variable "vpc_flow_log_kms_key_arn" {
  description = "Optional customer-managed KMS key ARN for VPC Flow Logs"
  type        = string
  default     = null
  nullable    = true
}

variable "enable_dns_hostnames" {
  description = "Enable DNS hostnames in VPC"
  type        = bool
  default     = true
}

variable "enable_dns_support" {
  description = "Enable DNS support in VPC"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
