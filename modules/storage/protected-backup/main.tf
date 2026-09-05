data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
locals {
  account    = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  bucket_arn = "arn:aws:s3:::${var.bucket_name}"
  object_arn = "${local.bucket_arn}/argocd/*"
  tags       = merge(var.tags, { ManagedBy = "Terraform" })
}
resource "aws_kms_key" "backup" {
  description             = "Protected Argo CD archive encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ExplicitKeyAdministrators", Effect = "Allow", Principal = { AWS = sort(tolist(var.administrator_role_arns)) }, Resource = "*"
        Action = ["kms:DescribeKey", "kms:GetKeyPolicy", "kms:PutKeyPolicy", "kms:ListKeyPolicies", "kms:EnableKeyRotation", "kms:GetKeyRotationStatus", "kms:TagResource", "kms:UntagResource", "kms:ListResourceTags", "kms:UpdateKeyDescription", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion"]
      },
      {
        Sid    = "ArchiveOperatorsViaS3", Effect = "Allow", Principal = { AWS = sort(tolist(var.operator_role_arns)) }, Resource = "*"
        Action = ["kms:GenerateDataKey", "kms:Decrypt"]
        Condition = {
          StringEquals = { "kms:ViaService" = "s3.${local.region}.amazonaws.com", "kms:CallerAccount" = local.account }
          StringLike   = { "kms:EncryptionContext:aws:s3:arn" = local.object_arn }
        }
      }
    ]
  })
  tags = local.tags
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = alltrue([for arn in setunion(var.administrator_role_arns, var.operator_role_arns) : split(":", arn)[4] == local.account])
      error_message = "Backup roles must belong to the actual provider account."
    }
    precondition {
      condition     = length(setintersection(var.administrator_role_arns, var.operator_role_arns)) == 0
      error_message = "Archive operators must not also be key administrators able to disable recovery."
    }
  }
}
resource "aws_s3_bucket" "backup" {
  bucket              = var.bucket_name
  object_lock_enabled = true
  force_destroy       = false
  tags                = local.tags
  lifecycle { prevent_destroy = true }
}
resource "aws_s3_bucket_public_access_block" "backup" {
  bucket                  = aws_s3_bucket.backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_ownership_controls" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule { object_ownership = "BucketOwnerEnforced" }
}
resource "aws_s3_bucket_versioning" "backup" {
  bucket = aws_s3_bucket.backup.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_object_lock_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = var.retention_days
    }
  }
  depends_on = [aws_s3_bucket_versioning.backup]
}
resource "aws_s3_bucket_server_side_encryption_configuration" "backup" {
  bucket = aws_s3_bucket.backup.id
  rule {
    bucket_key_enabled = false
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.backup.arn
    }
  }
}
resource "aws_s3_bucket_policy" "backup" {
  bucket = aws_s3_bucket.backup.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "TLSOnly", Effect = "Deny", Principal = "*", Action = "s3:*", Resource = [local.bucket_arn, "${local.bucket_arn}/*"], Condition = { Bool = { "aws:SecureTransport" = "false" } } },
      { Sid = "RequireKMS", Effect = "Deny", Principal = "*", Action = "s3:PutObject", Resource = local.object_arn, Condition = { StringNotEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" } } },
      { Sid = "RequireArchiveKey", Effect = "Deny", Principal = "*", Action = "s3:PutObject", Resource = local.object_arn, Condition = { StringNotEquals = { "s3:x-amz-server-side-encryption-aws-kms-key-id" = aws_kms_key.backup.arn } } },
      { Sid = "OperatorBucketRead", Effect = "Allow", Principal = { AWS = sort(tolist(var.operator_role_arns)) }, Action = ["s3:GetBucketLocation", "s3:GetBucketVersioning", "s3:GetBucketObjectLockConfiguration", "s3:GetEncryptionConfiguration", "s3:GetBucketPublicAccessBlock", "s3:GetBucketPolicyStatus", "s3:GetBucketOwnershipControls"], Resource = local.bucket_arn },
      { Sid = "OperatorArchiveReadWrite", Effect = "Allow", Principal = { AWS = sort(tolist(var.operator_role_arns)) }, Action = ["s3:PutObject", "s3:GetObject", "s3:GetObjectVersion", "s3:GetObjectRetention"], Resource = local.object_arn },
      { Sid = "OperatorCannotEraseArchive", Effect = "Deny", Principal = { AWS = sort(tolist(var.operator_role_arns)) }, Action = ["s3:DeleteObject", "s3:DeleteObjectVersion", "s3:BypassGovernanceRetention", "s3:PutObjectRetention"], Resource = local.object_arn }
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.backup]
}
