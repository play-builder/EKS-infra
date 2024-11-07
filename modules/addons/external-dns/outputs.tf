output "iam_role_arn" {
  description = "Created IAM Role ARN"
  value       = module.irsa_role.iam_role_arn
}

output "helm_release_metadata" {
  description = "Helm Release Metadata"
  value       = helm_release.external_dns.metadata
}