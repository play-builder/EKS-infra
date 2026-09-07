# dev account: Terraform state bucket.
# State for this root stays local (terraform.tfstate in this directory) because
# it creates the bucket that every other dev root uses as its remote backend.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      CourseId  = var.course_id
      Project   = var.project_name
      ManagedBy = "gitops-course"
    }
  }
}

data "aws_caller_identity" "current" {}

module "state_backend" {
  source = "../../../../modules/bootstrap/state-backend"

  bucket_name   = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"
  environment   = "dev"
  force_destroy = var.force_destroy
  tags          = var.tags
}
