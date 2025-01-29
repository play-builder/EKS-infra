
output "iam_policy_arn" {
  description = "ARN of the IAM Policy for AWS Load Balancer Controller"
  value       = aws_iam_policy.lbc.arn
}

output "iam_role_arn" {
  description = "ARN of the IAM Role for AWS Load Balancer Controller (IRSA)"
  value       = module.irsa_role.iam_role_arn
}

output "iam_role_name" {
  description = "Name of the IAM Role for AWS Load Balancer Controller"
  value       = module.irsa_role.iam_role_name
}


output "ingress_class_name" {
  description = "AWS LBC IngressClass name"
  value       = var.ingress_class_name
}

output "helm_release_name" {
  description = "Name of the Helm release"
  value       = helm_release.lbc.name
}

output "helm_release_namespace" {
  description = "Namespace of the Helm release"
  value       = helm_release.lbc.namespace
}

output "helm_release_version" {
  description = "Version of the Helm release"
  value       = helm_release.lbc.version
}

output "helm_release_status" {
  description = "Status of the Helm release"
  value       = helm_release.lbc.status
}

output "helm_release_metadata" {
  description = "Metadata block outlining status of the deployed release"
  value       = helm_release.lbc.metadata
}


output "is_default_ingress_class" {
  description = "Whether this is the default IngressClass"
  value       = var.is_default_class
}