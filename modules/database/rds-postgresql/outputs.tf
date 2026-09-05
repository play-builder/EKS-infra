output "database_contract" {
  description = "Resource and recovery-target metadata only; no credential values or achieved RPO/RTO."
  value = {
    schemaVersion           = "platform.database/v1"
    accountId               = data.aws_caller_identity.current.account_id
    region                  = data.aws_region.current.name
    identifier              = aws_db_instance.database.identifier
    arn                     = aws_db_instance.database.arn
    resourceId              = aws_db_instance.database.resource_id
    endpoint                = aws_db_instance.database.address
    port                    = aws_db_instance.database.port
    databaseName            = var.database_name
    engineVersion           = aws_db_instance.database.engine_version_actual
    caCertificateId         = aws_db_instance.database.ca_cert_identifier
    masterSecretArn         = try(aws_db_instance.database.master_user_secret[0].secret_arn, null)
    masterUsername          = local.is_restore ? data.aws_db_instance.source[0].master_username : var.master_username
    securityGroupId         = aws_security_group.database.id
    subnetGroupName         = aws_db_subnet_group.database.name
    storageKmsKeyArn        = aws_db_instance.database.kms_key_id
    backupRetentionDays     = aws_db_instance.database.backup_retention_period
    finalSnapshotIdentifier = var.final_snapshot_identifier
    expectedConfiguration = {
      caCertificateId     = var.ca_cert_identifier
      backupRetentionDays = var.backup_retention_days
      backupWindow        = "01:00-01:30"
      maintenanceWindow   = "sun:04:00-sun:05:00"
      parameterGroupName  = aws_db_parameter_group.database.name
    }
    objectives = {
      rpoMinutes      = var.recovery_objectives.rpo_minutes
      rtoMinutes      = var.recovery_objectives.rto_minutes
      drillMaxAgeDays = var.recovery_objectives.drill_max_age_days
    }
    restore = local.is_restore ? {
      sourceIdentifier               = var.restore_to_point_in_time.source_db_instance_identifier
      sourceArn                      = data.aws_db_instance.source[0].db_instance_arn
      sourceResourceId               = data.aws_db_instance.source[0].resource_id
      requestedTime                  = var.restore_to_point_in_time.restore_time
      useLatest                      = var.restore_to_point_in_time.use_latest_restorable_time
      targetIdentifier               = var.identifier
      requiresPostRestoreConvergence = true
      immediateReconciliationOptIn   = var.apply_restore_changes_immediately
    } : null
  }
}
