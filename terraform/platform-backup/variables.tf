variable "project_name" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,17}$", var.project_name))
    error_message = "project_name must be a 3-18 character lowercase identifier."
  }
}
variable "aws_region" {
  type = string
  validation {
    condition     = contains(["us-east-1", "ap-northeast-2"], var.aws_region)
    error_message = "Use us-east-1 or ap-northeast-2."
  }
}
variable "administrator_role_arns" { type = set(string) }
variable "operator_role_arns" { type = set(string) }
variable "retention_days" {
  type    = number
  default = 120
}
variable "tags" { type = map(string) }
