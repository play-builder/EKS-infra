variable "aws_region" {
  description = "AWS Region that owns the Terraform state bucket."
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "Globally unique S3 bucket name used by the remote backends."
  type        = string

  validation {
    condition     = length(var.bucket_name) >= 3 && length(var.bucket_name) <= 63
    error_message = "bucket_name must contain between 3 and 63 characters."
  }
}

variable "project_name" {
  description = "Stable course project identifier used for ownership tags."
  type        = string
}

variable "force_destroy" {
  description = "Whether Terraform may delete a non-empty state bucket. Keep false outside disposable sandboxes."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags applied to the state bucket."
  type        = map(string)
  default     = {}
}
