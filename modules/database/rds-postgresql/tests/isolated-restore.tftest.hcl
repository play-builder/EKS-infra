mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_region" { defaults = { name = "us-east-1" } }
  mock_data "aws_subnet" { defaults = { vpc_id = "vpc-0123456789abcdef0", availability_zone = "us-east-1a", map_public_ip_on_launch = false } }
  mock_data "aws_security_group" { defaults = { vpc_id = "vpc-0123456789abcdef0" } }
  mock_data "aws_db_instance" {
    defaults = {
      db_instance_arn         = "arn:aws:rds:us-east-1:123456789012:db:commerce-prod"
      resource_id             = "db-ABCDEFGHIJKLMNOPQRSTUVWXY1"
      engine                  = "postgres"
      engine_version          = "17.6"
      db_name                 = "commerce"
      master_username         = "platform_admin"
      storage_encrypted       = true
      backup_retention_period = 35
      publicly_accessible     = false
      allocated_storage       = 40
      kms_key_id              = "arn:aws:kms:us-east-1:123456789012:key/12345678-1234-1234-1234-123456789012"
    }
  }
}
override_data {
  target = data.aws_subnet.database["subnet-1123456789abcdef0"]
  values = { vpc_id = "vpc-0123456789abcdef0", availability_zone = "us-east-1b", map_public_ip_on_launch = false }
}

variables {
  identifier                = "commerce-restore-20260905"
  vpc_id                    = "vpc-0123456789abcdef0"
  subnet_ids                = ["subnet-0123456789abcdef0", "subnet-1123456789abcdef0"]
  client_security_group_ids = ["sg-0123456789abcdef0"]
  engine_version            = "17.6"
  instance_class            = "db.m7g.large"
  ca_cert_identifier        = "rds-ca-rsa2048-g1"
  final_snapshot_identifier = "commerce-restore-final-20260905"
  restore_to_point_in_time = {
    source_db_instance_identifier = "commerce-prod"
    restore_time                  = "2026-09-04T00:00:00Z"
  }
  tags = {
    PlatformInstanceId = "commerce-dr-123"
    Owner              = "platform-sre"
    CostCenter         = "cc-100"
    Environment        = "prod"
  }
}

run "pitr_creates_separate_target_and_inherits_encrypted_storage" {
  command = plan
  assert {
    condition = (
      aws_db_instance.database.identifier == "commerce-restore-20260905" &&
      one(aws_db_instance.database.restore_to_point_in_time).source_db_instance_identifier == "commerce-prod" &&
      one(aws_db_instance.database.restore_to_point_in_time).restore_time == "2026-09-04T00:00:00Z" &&
      one(aws_db_instance.database.restore_to_point_in_time).use_latest_restorable_time == null &&
      aws_db_instance.database.allocated_storage == 40 &&
      aws_db_instance.database.kms_key_id == data.aws_db_instance.source[0].kms_key_id &&
      output.database_contract.restore.sourceArn == "arn:aws:rds:us-east-1:123456789012:db:commerce-prod" &&
      output.database_contract.objectives.rpoMinutes == 60
    )
    error_message = "An isolated PITR target must preserve the source storage key/capacity and explicit cutoff without modifying source identity."
  }
}
run "rejects_future_cutoff" {
  command = plan
  variables { restore_to_point_in_time = { source_db_instance_identifier = "commerce-prod", restore_time = "2099-01-01T00:00:00Z" } }
  expect_failures = [aws_db_instance.database]
}
run "rejects_unencrypted_source" {
  command = plan
  override_data {
    target = data.aws_db_instance.source[0]
    values = {
      db_instance_arn         = "arn:aws:rds:us-east-1:123456789012:db:commerce-prod"
      engine                  = "postgres"
      engine_version          = "17.6"
      db_name                 = "commerce"
      storage_encrypted       = false
      backup_retention_period = 35
      publicly_accessible     = false
      allocated_storage       = 40
    }
  }
  expect_failures = [aws_db_instance.database]
}
run "rejects_changing_source_storage_key" {
  command = plan
  variables { storage_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/22345678-1234-1234-1234-123456789012" }
  expect_failures = [aws_db_instance.database]
}
run "isolated_target_can_opt_into_reviewed_immediate_convergence" {
  command = plan
  variables { apply_restore_changes_immediately = true }
  assert {
    condition = (
      aws_db_instance.database.apply_immediately &&
      output.database_contract.restore.requiresPostRestoreConvergence &&
      output.database_contract.expectedConfiguration.caCertificateId == "rds-ca-rsa2048-g1" &&
      output.database_contract.expectedConfiguration.backupRetentionDays == 35 &&
      output.database_contract.expectedConfiguration.backupWindow == "01:00-01:30" &&
      output.database_contract.expectedConfiguration.maintenanceWindow == "sun:04:00-sun:05:00"
    )
    error_message = "Restore handoff must expose intended convergence targets without claiming observed readiness."
  }
}
