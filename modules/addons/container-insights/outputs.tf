output "namespace" {
  description = "Kubernetes namespace for Container Insights"
  value       = kubernetes_namespace_v1.amazon_cloudwatch.metadata[0].name
}

output "iam_role_arn" {
  description = "IAM Role ARN for Container Insights"
  value       = module.irsa_role.iam_role_arn
}

output "cloudwatch_agent_release_name" {
  description = "CloudWatch Agent Helm release name"
  value       = helm_release.cloudwatch_agent.name
}

output "fluent_bit_release_name" {
  description = "Fluent Bit Helm release name"
  value       = helm_release.fluent_bit.name
}