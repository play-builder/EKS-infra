mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_region" { defaults = { name = "ap-northeast-2" } }
}
variables {
  project_name            = "commerce"
  course_id               = "commerce-2026"
  aws_region              = "ap-northeast-2"
  administrator_role_arns = ["arn:aws:iam::123456789012:role/backup-admin"]
  operator_role_arns      = ["arn:aws:iam::123456789012:role/backup-operator"]
  tags                    = { PlatformInstanceId = "commerce-123", Owner = "platform-sre", CostCenter = "cc-123" }
}
run "inventory_identity_cannot_be_overridden" {
  command = plan
  variables {
    tags = { PlatformInstanceId = "commerce-123", Owner = "platform-sre", CostCenter = "cc-123", AccountId = "999999999999", CourseId = "other-owner", Region = "us-east-1", Layer = "network" }
  }
  assert {
    condition     = try(output.backup.tags.CourseId == "commerce-2026" && output.backup.tags.AccountId == "123456789012" && output.backup.tags.Region == "ap-northeast-2" && output.backup.tags.Project == "commerce" && output.backup.tags.Layer == "platform-backup", false)
    error_message = "Protected backup must remain discoverable by actual account/region and retained-resource ownership scope."
  }
}
run "isolated_backup_lifetime_and_region" {
  command = plan
  assert {
    condition     = output.backup.bucketArn == "arn:aws:s3:::commerce-argocd-backup-123456789012-ap-northeast-2" && output.backup.tags.Environment == "prod" && output.backup.region == "ap-northeast-2"
    error_message = "Backup root must remain separate from cluster roots and bind actual Region/account."
  }
}
