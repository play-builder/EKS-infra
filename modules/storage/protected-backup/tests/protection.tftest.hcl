mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_region" { defaults = { name = "us-east-1" } }
}
variables {
  bucket_name             = "commerce-control-plane-backup-123456789012"
  administrator_role_arns = ["arn:aws:iam::123456789012:role/backup-admin"]
  operator_role_arns      = ["arn:aws:iam::123456789012:role/backup-operator"]
  tags                    = { PlatformInstanceId = "commerce-123", Owner = "platform-sre", CostCenter = "cc-123", Environment = "prod" }
}
run "rejects_short_retention" {
  command = plan
  variables { retention_days = 89 }
  expect_failures = [var.retention_days]
}
run "rejects_wildcard_operator" {
  command = plan
  variables { operator_role_arns = ["*"] }
  expect_failures = [var.operator_role_arns]
}
run "rejects_empty_administrator" {
  command = plan
  variables { administrator_role_arns = [] }
  expect_failures = [var.administrator_role_arns]
}
run "rejects_missing_owner" {
  command = plan
  variables { tags = { Environment = "prod" } }
  expect_failures = [var.tags]
}
run "protected_archive_contract" {
  command = plan
  assert {
    condition     = try(output.backup.schemaVersion == "platform.backup-storage/v1" && output.backup.retentionDays == 120 && output.backup.objectLockMode == "GOVERNANCE" && output.backup.region == "us-east-1" && output.backup.prefix == "argocd/", false)
    error_message = "The backup producer must publish protected, versioned archive metadata."
  }
  assert {
    condition     = aws_s3_bucket.backup.object_lock_enabled && !aws_s3_bucket.backup.force_destroy && one(aws_s3_bucket_versioning.backup.versioning_configuration).status == "Enabled" && aws_s3_bucket_public_access_block.backup.block_public_policy && aws_kms_key.backup.enable_key_rotation
    error_message = "Archive must have versioning, deletion protection, private access and rotating encryption."
  }
  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.backup.rule).bucket_key_enabled == false && one(one(aws_s3_bucket_server_side_encryption_configuration.backup.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "Object-scoped KMS context requires bucket keys disabled."
  }
  assert {
    condition     = jsondecode(aws_kms_key.backup.policy).Statement[1].Condition.StringLike["kms:EncryptionContext:aws:s3:arn"] == "arn:aws:s3:::commerce-control-plane-backup-123456789012/argocd/*" && !contains(jsondecode(aws_kms_key.backup.policy).Statement[1].Action, "kms:ScheduleKeyDeletion")
    error_message = "Archive operator encryption is constrained to the exact object prefix, not key administration."
  }
}
run "rejects_external_account_administrator" {
  command = plan
  variables { administrator_role_arns = ["arn:aws:iam::999999999999:role/backup-admin"] }
  expect_failures = [aws_kms_key.backup]
}
run "rejects_operator_key_administration_overlap" {
  command = plan
  variables { operator_role_arns = ["arn:aws:iam::123456789012:role/backup-admin"] }
  expect_failures = [aws_kms_key.backup]
}
