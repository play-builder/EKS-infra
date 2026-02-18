output "workspace_id" {
  description = "AMP workspace ID"
  value       = aws_prometheus_workspace.this.id
}

output "workspace_arn" {
  description = "AMP workspace ARN"
  value       = aws_prometheus_workspace.this.arn
}

output "workspace_prometheus_endpoint" {
  description = "Prometheus endpoint for remote write (use with /api/v1/remote_write)"
  value       = aws_prometheus_workspace.this.prometheus_endpoint
}