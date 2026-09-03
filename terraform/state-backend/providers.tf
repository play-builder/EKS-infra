provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(var.tags, {
      CourseId    = var.course_id
      Region      = var.aws_region
      Environment = "shared"
      Layer       = "state-backend"
      ManagedBy   = "gitops-course"
      Project     = var.project_name
    })
  }
}
