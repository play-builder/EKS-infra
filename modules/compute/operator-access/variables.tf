variable "name" { type = string }
variable "vpc_id" { type = string }
variable "subnet_id" { type = string }
variable "cluster_arn" { type = string }
variable "operator_role_arn" { type = string }
variable "ami_id" { type = string }

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "mode" {
  type    = string
  default = "ssm"

  validation {
    condition     = var.mode == "ssm"
    error_message = "Operator access mode must be ssm."
  }
}
