output "namespace" { value = kubernetes_namespace_v1.amazon_cloudwatch.metadata[0].name }
output "iam_role_arn" {
  description = "Legacy output retained: CloudWatch agent only. Fluent Bit has a distinct role."
  value       = aws_iam_role.cloudwatch_agent.arn
}
output "fluent_bit_iam_role_arn" { value = aws_iam_role.fluent_bit.arn }
output "cloudwatch_agent_release_name" { value = helm_release.cloudwatch_agent.name }
output "fluent_bit_release_name" { value = helm_release.fluent_bit.name }
output "audit_log_groups" {
  value = tomap({ for kind, group in aws_cloudwatch_log_group.this : kind => {
    arn            = local.group_arns[kind]
    retention_days = group.retention_in_days
    kms_key_arn    = group.kms_key_id
  } })
}
