locals {
  owned_tags            = merge(var.tags, { ManagedBy = "Terraform" })
  log_group_arns        = sort([for name in var.log_group_names : "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:${name}"])
  cryptographic_actions = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncryptFrom", "kms:ReEncryptTo", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext", "kms:DescribeKey"]
}
resource "aws_kms_key" "this" {
  description                        = "CloudWatch log protection for ${var.name}"
  key_usage                          = "ENCRYPT_DECRYPT"
  customer_master_key_spec           = "SYMMETRIC_DEFAULT"
  enable_key_rotation                = true
  deletion_window_in_days            = 30
  bypass_policy_lockout_safety_check = false
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid       = "ExplicitAdministrators"
        Effect    = "Allow"
        Principal = { AWS = sort(tolist(var.administrator_role_arns)) }
        Action    = ["kms:DescribeKey", "kms:GetKeyPolicy", "kms:PutKeyPolicy", "kms:ListKeyPolicies", "kms:EnableKey", "kms:DisableKey", "kms:EnableKeyRotation", "kms:DisableKeyRotation", "kms:GetKeyRotationStatus", "kms:RotateKeyOnDemand", "kms:UpdateKeyDescription", "kms:TagResource", "kms:UntagResource", "kms:ListResourceTags", "kms:ScheduleKeyDeletion", "kms:CancelKeyDeletion", "kms:CreateAlias", "kms:UpdateAlias", "kms:DeleteAlias"]
        Resource  = "*"
      },
      {
        Sid       = "RegionalLogsExactContext"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }
        Action    = local.cryptographic_actions
        Resource  = "*"
        Condition = { ArnEquals = { "kms:EncryptionContext:aws:logs:arn" = local.log_group_arns } }
      }
      ], length(var.caller_role_arns) == 0 ? [] : [{
        Sid    = "LogCallersViaRegionalLogs"
        Effect = "Allow"
        # Exact role conditions allow 01-network to precede role creation in 03-platform.
        # Account delegation still requires each caller's identity policy to allow this key.
        Principal = { AWS = "arn:aws:iam::${var.account_id}:root" }
        Action    = local.cryptographic_actions
        Resource  = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "logs.${var.aws_region}.amazonaws.com" }
          ArnEquals = {
            "aws:PrincipalArn"                   = sort(tolist(var.caller_role_arns))
            "kms:EncryptionContext:aws:logs:arn" = local.log_group_arns
          }
        }
    }])
  })
  tags = local.owned_tags
}
resource "aws_kms_alias" "this" {
  name          = "alias/${var.name}-logs"
  target_key_id = aws_kms_key.this.key_id
}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
