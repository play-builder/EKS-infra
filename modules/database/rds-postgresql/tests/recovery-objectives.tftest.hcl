mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_region" { defaults = { name = "us-east-1" } }
  mock_data "aws_subnet" { defaults = { vpc_id = "vpc-0123456789abcdef0", availability_zone = "us-east-1a", map_public_ip_on_launch = false } }
  mock_data "aws_security_group" { defaults = { vpc_id = "vpc-0123456789abcdef0" } }
}
override_data {
  target = data.aws_subnet.database["subnet-1123456789abcdef0"]
  values = { vpc_id = "vpc-0123456789abcdef0", availability_zone = "us-east-1b", map_public_ip_on_launch = false }
}

variables {
  identifier                = "commerce-prod"
  vpc_id                    = "vpc-0123456789abcdef0"
  subnet_ids                = ["subnet-0123456789abcdef0", "subnet-1123456789abcdef0"]
  client_security_group_ids = ["sg-0123456789abcdef0"]
  engine_version            = "17.6"
  instance_class            = "db.m7g.large"
  ca_cert_identifier        = "rds-ca-rsa2048-g1"
  final_snapshot_identifier = "commerce-prod-final-20260905"
  tags = {
    PlatformInstanceId = "commerce-123"
    Owner              = "platform-sre"
    CostCenter         = "cc-100"
    Environment        = "prod"
  }
}

run "rejects_disabled_backups" {
  command = plan
  variables { backup_retention_days = 0 }
  expect_failures = [var.backup_retention_days]
}
run "rejects_insufficient_retention" {
  command = plan
  variables { backup_retention_days = 1 }
  expect_failures = [var.backup_retention_days]
}
run "rejects_zero_recovery_objective" {
  command = plan
  variables { recovery_objectives = { rpo_minutes = 0, rto_minutes = 120, drill_max_age_days = 30 } }
  expect_failures = [var.recovery_objectives]
}
run "rejects_source_as_restore_target" {
  command = plan
  variables { restore_to_point_in_time = { source_db_instance_identifier = "commerce-prod", use_latest_restorable_time = true } }
  expect_failures = [var.restore_to_point_in_time]
}
run "rejects_ambiguous_restore_cutoff" {
  command = plan
  variables { restore_to_point_in_time = { source_db_instance_identifier = "commerce-source", restore_time = "2026-09-05T00:00:00Z", use_latest_restorable_time = true } }
  expect_failures = [var.restore_to_point_in_time]
}
run "rejects_missing_restore_cutoff" {
  command = plan
  variables { restore_to_point_in_time = { source_db_instance_identifier = "commerce-source" } }
  expect_failures = [var.restore_to_point_in_time]
}
run "rejects_missing_client_identity" {
  command = plan
  variables { client_security_group_ids = [] }
  expect_failures = [var.client_security_group_ids]
}
run "rejects_missing_ownership_tags" {
  command = plan
  variables { tags = {} }
  expect_failures = [var.tags]
}
run "rejects_immediate_restore_flag_in_production_root" {
  command = plan
  variables { apply_restore_changes_immediately = true }
  expect_failures = [var.apply_restore_changes_immediately]
}
