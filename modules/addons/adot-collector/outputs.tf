output "iam_role_arn" {
  description = "IAM Role ARN for ADOT Collector"
  value       = aws_iam_role.adot.arn
}

output "addon_version" {
  description = "ADOT EKS addon version"
  value       = aws_eks_addon.adot.addon_version
}

output "otlp_http_traces_endpoint" {
  description = "In-cluster OTLP/HTTP protobuf endpoint for application traces"
  value       = var.enable_xray ? "http://adot-collector-prometheus-collector.opentelemetry-operator-system.svc.cluster.local:4318/v1/traces" : null
}

output "otlp_traces_protocol" {
  description = "Application trace protocol accepted by the collector"
  value       = var.enable_xray ? "http/protobuf" : null
}

output "otlp_http_port" {
  description = "In-cluster OTLP HTTP receiver port when the X-Ray pipeline is active"
  value       = var.enable_xray ? 4318 : null
}

output "otlp_http_traces_path" {
  description = "OTLP HTTP protobuf traces path when the X-Ray pipeline is active"
  value       = var.enable_xray ? "/v1/traces" : null
}

output "xray_enabled" {
  description = "Whether the OTLP receiver and AWS X-Ray exporter pipeline are active"
  value       = var.enable_xray
}
