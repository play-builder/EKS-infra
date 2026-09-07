variable "aws_region" {
  description = "Region for the state bucket. Must match the profile region."
  type        = string

  validation {
    condition     = contains(["ap-northeast-2", "us-east-1"], var.aws_region)
    error_message = "aws_region must be ap-northeast-2 or us-east-1."
  }
}

variable "project_name" {
  description = "Resource name prefix shared by every root"
  type        = string
  default     = "mini-commerce"
}

variable "force_destroy" {
  description = "Allow deleting the bucket with objects inside. Enable only in disposable accounts."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
