output "web_acl_arn" {
  description = "GitOps owns the ALB association; this output is not association or blocking evidence."
  value       = aws_wafv2_web_acl.this.arn
}
output "log_group_arn" { value = local.log_group_arn }
output "audit_log_groups" {
  value = tomap({ waf = {
    arn            = local.log_group_arn
    retention_days = aws_cloudwatch_log_group.waf.retention_in_days
    kms_key_arn    = aws_cloudwatch_log_group.waf.kms_key_id
  } })
}

