variable "aws_region" {
  description = "AWS Region that owns the Terraform state bucket."
  type        = string

  validation {
    condition     = contains(["ap-northeast-2", "us-east-1"], var.aws_region)
    error_message = "aws_region must be ap-northeast-2 or us-east-1."
  }
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

variable "course_id" {
  description = "Unique CourseId binding the remote state bucket to cleanup evidence"
  type        = string
  default     = "course-2026"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{7,62}$", var.course_id))
    error_message = "course_id must be a unique 8-63 character lowercase identifier."
  }
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
