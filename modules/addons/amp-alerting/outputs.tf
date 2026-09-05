output "enabled" {
  description = "Whether AMP rules are enabled"
  value       = var.enabled
}

output "slo" {
  description = "Typed SLO consumed by GitOps and captured-evidence validation; not live readiness."
  value       = var.slo
}

output "rules_yaml" {
  description = "Exact raw provider payload for offline promtool validation."
  value       = yamlencode(local.rule_groups)
}

output "sns_delivery_enabled" {
  description = "Whether an SNS route and subscription are declared"
  value       = local.subscription_enabled
}

output "sns_topic_arn" {
  description = "SNS topic used by AMP Alertmanager"
  value       = var.enabled ? aws_sns_topic.course_alerts[0].arn : null
}

output "rule_group_namespace" {
  description = "AMP rule group namespace"
  value       = var.enabled ? aws_prometheus_rule_group_namespace.course[0].name : null
}
