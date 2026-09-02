provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(var.tags, {
      ManagedBy = "gitops-course"
      Project   = var.project_name
    })
  }
}
