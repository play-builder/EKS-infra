provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.expected_account_id]
}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
