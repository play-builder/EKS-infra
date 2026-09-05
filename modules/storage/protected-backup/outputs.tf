output "backup" {
  value = {
    schemaVersion    = "platform.backup-storage/v1"
    accountId        = local.account
    region           = local.region
    bucket           = aws_s3_bucket.backup.id
    bucketArn        = local.bucket_arn
    prefix           = "argocd/"
    kmsKeyArn        = aws_kms_key.backup.arn
    objectLockMode   = "GOVERNANCE"
    retentionDays    = var.retention_days
    operatorRoleArns = sort(tolist(var.operator_role_arns))
    tags             = local.tags
  }
}
