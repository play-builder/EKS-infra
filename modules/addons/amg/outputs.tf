output "workspace_id" {
  description = "Grafana workspace ID"
  value       = aws_grafana_workspace.this.id
}

output "workspace_endpoint" {
  description = "Grafana workspace URL"
  value       = aws_grafana_workspace.this.endpoint
}

output "workspace_arn" {
  description = "Grafana workspace ARN"
  value       = aws_grafana_workspace.this.arn
}

output "iam_role_arn" {
  description = "IAM role ARN used by Grafana"
  value       = aws_iam_role.amg.arn
}