variable "aws_region" {
  type = string
  validation {
    condition     = contains(["ap-northeast-2", "us-east-1"], var.aws_region)
    error_message = "aws_region must be ap-northeast-2 or us-east-1."
  }
}

variable "environment" {
  type    = string
  default = "dev"
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "project_name" {
  type    = string
  default = "mini-commerce"
}

variable "root_domain" {
  description = "Apex domain owned by the network account, e.g. example.com"
  type        = string
}
