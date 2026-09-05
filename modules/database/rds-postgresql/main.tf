data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_subnet" "database" {
  for_each = var.subnet_ids
  id       = each.value
}
data "aws_security_group" "client" {
  for_each = var.client_security_group_ids
  id       = each.value
}
data "aws_db_instance" "source" {
  count                  = var.restore_to_point_in_time == null ? 0 : 1
  db_instance_identifier = var.restore_to_point_in_time.source_db_instance_identifier
}

locals {
  is_restore = var.restore_to_point_in_time != null
  tags       = merge(var.tags, { ManagedBy = "Terraform" })
}

resource "aws_db_subnet_group" "database" {
  name        = "${var.identifier}-database"
  description = "Private PostgreSQL database subnets"
  subnet_ids  = var.subnet_ids
  tags        = local.tags

  lifecycle {
    precondition {
      condition     = alltrue([for subnet in data.aws_subnet.database : subnet.vpc_id == var.vpc_id && !subnet.map_public_ip_on_launch]) && length(toset([for subnet in data.aws_subnet.database : subnet.availability_zone])) >= 2
      error_message = "Database subnets must belong to the selected VPC, disable public IP assignment and span at least two AZs. Verify private route tables before deployment."
    }
  }
}

resource "aws_security_group" "database" {
  name        = "${var.identifier}-postgresql"
  description = "PostgreSQL ingress from explicit application and operator identities"
  vpc_id      = var.vpc_id
  egress      = []
  tags        = local.tags
}
resource "aws_vpc_security_group_ingress_rule" "client" {
  for_each                     = var.client_security_group_ids
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "Explicit PostgreSQL client security group"
  tags                         = local.tags
  lifecycle {
    precondition {
      condition     = data.aws_security_group.client[each.key].vpc_id == var.vpc_id
      error_message = "Database client security groups must belong to the database VPC."
    }
  }
}
resource "aws_db_parameter_group" "database" {
  name        = "${var.identifier}-postgresql${split(".", var.engine_version)[0]}"
  family      = "postgres${split(".", var.engine_version)[0]}"
  description = "PostgreSQL TLS enforcement without statement payload logging"
  tags        = local.tags
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }
  parameter {
    name         = "log_statement"
    value        = "none"
    apply_method = "pending-reboot"
  }
  parameter {
    name         = "log_min_error_statement"
    value        = "panic"
    apply_method = "pending-reboot"
  }
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "database" {
  identifier                  = var.identifier
  engine                      = "postgres"
  engine_version              = var.engine_version
  instance_class              = var.instance_class
  allocated_storage           = local.is_restore ? data.aws_db_instance.source[0].allocated_storage : var.allocated_storage
  max_allocated_storage       = var.max_allocated_storage
  storage_type                = "gp3"
  storage_encrypted           = true
  kms_key_id                  = local.is_restore ? data.aws_db_instance.source[0].kms_key_id : var.storage_kms_key_arn
  db_name                     = local.is_restore ? null : var.database_name
  username                    = local.is_restore ? null : var.master_username
  manage_master_user_password = true
  db_subnet_group_name        = aws_db_subnet_group.database.name
  vpc_security_group_ids      = [aws_security_group.database.id]
  parameter_group_name        = aws_db_parameter_group.database.name
  ca_cert_identifier          = var.ca_cert_identifier
  port                        = 5432
  publicly_accessible         = false
  multi_az                    = true
  backup_retention_period     = var.backup_retention_days
  backup_window               = "01:00-01:30"
  maintenance_window          = "sun:04:00-sun:05:00"
  deletion_protection         = var.deletion_protection
  skip_final_snapshot         = false
  final_snapshot_identifier   = var.final_snapshot_identifier
  delete_automated_backups    = false
  copy_tags_to_snapshot       = true
  apply_immediately           = local.is_restore && var.apply_restore_changes_immediately
  auto_minor_version_upgrade  = false
  allow_major_version_upgrade = false
  tags                        = local.tags

  dynamic "restore_to_point_in_time" {
    for_each = local.is_restore ? [var.restore_to_point_in_time] : []
    content {
      source_db_instance_identifier = restore_to_point_in_time.value.source_db_instance_identifier
      restore_time                  = restore_to_point_in_time.value.restore_time
      use_latest_restorable_time    = restore_to_point_in_time.value.restore_time == null ? true : null
    }
  }
  lifecycle {
    precondition {
      condition = !local.is_restore ? true : (
        var.max_allocated_storage >= ceil(data.aws_db_instance.source[0].allocated_storage * 1.1)
      )
      error_message = "The restored DB inherits source capacity; its autoscaling maximum must remain at least 10 percent above that capacity."
    }
    precondition {
      condition = !local.is_restore ? true : (
        var.restore_to_point_in_time.restore_time == null ? true : timecmp(var.restore_to_point_in_time.restore_time, plantimestamp()) <= 0
      )
      error_message = "The requested PITR cutoff must not be in the future; validate it against the live restorable window before apply."
    }
    precondition {
      condition = var.storage_kms_key_arn == null ? true : (
        split(":", var.storage_kms_key_arn)[3] == data.aws_region.current.name &&
        split(":", var.storage_kms_key_arn)[4] == data.aws_caller_identity.current.account_id
      )
      error_message = "Storage encryption key must belong to the selected account and workload Region."
    }
    precondition {
      condition = !local.is_restore ? true : (
        data.aws_db_instance.source[0].engine == "postgres" &&
        data.aws_db_instance.source[0].engine_version == var.engine_version &&
        data.aws_db_instance.source[0].db_name == var.database_name &&
        data.aws_db_instance.source[0].storage_encrypted &&
        data.aws_db_instance.source[0].backup_retention_period >= 7 &&
        !data.aws_db_instance.source[0].publicly_accessible &&
        data.aws_db_instance.source[0].db_instance_arn == "arn:aws:rds:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:db:${var.restore_to_point_in_time.source_db_instance_identifier}" &&
        (var.storage_kms_key_arn == null ? true : var.storage_kms_key_arn == data.aws_db_instance.source[0].kms_key_id)
      )
      error_message = "PITR source must be the exact same-account/Region private encrypted PostgreSQL DB with backups, matching version/database and unchanged storage key."
    }
  }
}
