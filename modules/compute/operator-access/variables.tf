variable "name" { type = string }
variable "vpc_id" { type = string }
variable "subnet_id" { type = string }
variable "cluster_arn" { type = string }
variable "cluster_security_group_id" {
  description = "EKS-created cluster security group receiving HTTPS from the operator security group"
  type        = string
}
variable "trusted_sso_principal_arn" {
  type = string
  validation {
    condition     = can(regex("^arn:aws(-[a-z]+)?:iam::[0-9]{12}:role/(aws-reserved/sso.amazonaws.com/[^/]+/)?AWSReservedSSO_.+", var.trusted_sso_principal_arn))
    error_message = "OPERATOR_ACCESS_ROLE_TRUST_INVALID"
  }
}
variable "cluster_name" { type = string }
variable "ami_id" { type = string }

variable "kubectl_version" {
  type    = string
  default = "1.36.0"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.kubectl_version))
    error_message = "kubectl_version must be an exact semantic version."
  }
}

variable "authorization_namespace" {
  type    = string
  default = "platform-system"

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", var.authorization_namespace))
    error_message = "authorization_namespace must be a DNS label."
  }
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "tags" {
  type    = map(string)
  default = {}

  validation {
    condition = alltrue([
      for key in ["PlatformInstanceId", "Owner", "CostCenter", "Environment"] :
      try(length(trimspace(var.tags[key])) > 0, false)
    ])
    error_message = "PLATFORM_TAGS_REQUIRED: operator resources require nonblank PlatformInstanceId, Owner, CostCenter, and Environment tags."
  }
}

variable "mode" {
  type    = string
  default = "ssm"

  validation {
    condition     = var.mode == "ssm"
    error_message = "Operator access mode must be ssm."
  }
}
