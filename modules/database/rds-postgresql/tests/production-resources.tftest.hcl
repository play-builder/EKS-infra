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

run "database_uses_protected_private_encrypted_multiaz_defaults" {
  command = plan
  assert {
    condition = (
      aws_db_instance.database.publicly_accessible == false &&
      aws_db_instance.database.multi_az == true &&
      aws_db_instance.database.storage_encrypted == true &&
      aws_db_instance.database.backup_retention_period == 35 &&
      aws_db_instance.database.deletion_protection == true &&
      aws_db_instance.database.skip_final_snapshot == false &&
      aws_db_instance.database.delete_automated_backups == false &&
      aws_db_instance.database.manage_master_user_password == true &&
      aws_db_instance.database.password == null
    )
    error_message = "A managed password alone does not provide private Multi-AZ, encryption, PITR retention or deletion safety."
  }
  assert {
    condition = (
      aws_db_instance.database.parameter_group_name == aws_db_parameter_group.database.name &&
      aws_db_parameter_group.database.family == "postgres17" &&
      contains([for p in aws_db_parameter_group.database.parameter : "${p.name}=${p.value}"], "rds.force_ssl=1") &&
      contains([for p in aws_db_parameter_group.database.parameter : "${p.name}=${p.value}"], "log_statement=none") &&
      aws_db_instance.database.ca_cert_identifier == "rds-ca-rsa2048-g1" &&
      aws_db_instance.database.auto_minor_version_upgrade == false &&
      aws_db_instance.database.allow_major_version_upgrade == false &&
      aws_db_instance.database.copy_tags_to_snapshot == true &&
      aws_db_instance.database.apply_immediately == false
    )
    error_message = "The DB must use its TLS parameter group/CA and controlled patching with tagged retained snapshots."
  }
  assert {
    condition = alltrue([for rule in aws_vpc_security_group_ingress_rule.client :
      rule.referenced_security_group_id == "sg-0123456789abcdef0" && rule.ip_protocol == "tcp" &&
      rule.from_port == 5432 && rule.to_port == 5432 && rule.cidr_ipv4 == null && rule.cidr_ipv6 == null
    ]) && length(aws_security_group.database.egress) == 0 && aws_db_subnet_group.database.tags.ManagedBy == "Terraform"
    error_message = "Only identity-scoped PostgreSQL ingress is allowed; unmanaged broad egress must not appear."
  }
}

run "rejects_subnets_in_one_az" {
  command = plan
  override_data {
    target = data.aws_subnet.database["subnet-1123456789abcdef0"]
    values = { vpc_id = "vpc-0123456789abcdef0", availability_zone = "us-east-1a", map_public_ip_on_launch = false }
  }
  expect_failures = [aws_db_subnet_group.database]
}
run "rejects_public_ip_subnet" {
  command = plan
  override_data {
    target = data.aws_subnet.database["subnet-1123456789abcdef0"]
    values = { vpc_id = "vpc-0123456789abcdef0", availability_zone = "us-east-1b", map_public_ip_on_launch = true }
  }
  expect_failures = [aws_db_subnet_group.database]
}
run "rejects_client_group_in_another_vpc" {
  command = plan
  override_data {
    target = data.aws_security_group.client["sg-0123456789abcdef0"]
    values = { vpc_id = "vpc-1123456789abcdef0" }
  }
  expect_failures = [aws_vpc_security_group_ingress_rule.client]
}
run "rejects_encryption_key_in_another_region" {
  command = plan
  variables { storage_kms_key_arn = "arn:aws:kms:ap-northeast-2:123456789012:key/12345678-1234-1234-1234-123456789012" }
  expect_failures = [aws_db_instance.database]
}

run "keeps_remote_ingress_owned_by_standalone_rules" {
  command = apply
  override_resource {
    target = aws_security_group.database
    values = {
      ingress = [{ description = "Explicit PostgreSQL client security group", from_port = 5432, to_port = 5432, protocol = "tcp", security_groups = ["sg-0123456789abcdef0"], cidr_blocks = [], ipv6_cidr_blocks = [], prefix_list_ids = [], self = false }]
    }
  }
  assert {
    condition     = length(aws_security_group.database.ingress) == 1
    error_message = "The parent security group must leave observed ingress unmanaged; an explicit empty inline set conflicts with standalone rule ownership."
  }
}
