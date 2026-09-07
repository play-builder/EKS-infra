variable "bucket_name" {
  description = "Globally unique S3 bucket name. Convention: <project>-tfstate-<account id>"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 characters of lowercase letters, digits, dots, or hyphens."
  }
}

variable "environment" {
  description = "Account role that owns this bucket: network, dev, or prod"
  type        = string

  validation {
    condition     = contains(["network", "dev", "prod"], var.environment)
    error_message = "environment must be network, dev, or prod."
  }
}

variable "force_destroy" {
  description = "Allow Terraform to delete the bucket with objects inside. Enable only in disposable accounts."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags merged into every resource"
  type        = map(string)
  default     = {}
}
