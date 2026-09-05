variable "course_id" {
  type    = string
  default = "course-2026"
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{7,62}$", var.course_id))
    error_message = "Use the same explicit CourseId as the parent network and platform."
  }
}
variable "project_name" {
  type    = string
  default = "playdevops"
}
locals {
  owned_tags = merge(var.tags, {
    CourseId    = var.course_id
    Project     = var.project_name
    AccountId   = var.expected_account_id
    Region      = var.aws_region
    Environment = "prod"
    Layer       = "database"
    ManagedBy   = "Terraform"
  })
}
