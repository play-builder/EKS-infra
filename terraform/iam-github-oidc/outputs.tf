output "github_actions_role_arn" {
  description = "Backward-compatible alias for the EKS-infra role ARN"
  value       = aws_iam_role.infra.arn
}

output "infra_role_arn" {
  description = "EKS-infra GitHub Actions role ARN"
  value       = aws_iam_role.infra.arn
}

output "sample_app_push_role_arn" {
  description = "cicd-course-sample-app ECR push role ARN"
  value       = aws_iam_role.sample_app_push.arn
}

output "sample_app_supply_chain_role_arn" {
  description = "Repository-scoped role mapped to sample-app AWS_ATTEST_VERIFY_ROLE_ARN"
  value       = aws_iam_role.sample_app_supply_chain.arn
}

output "sample_app_ecr_repository_url" {
  description = "ECR repository URL written into argocd-gitops env values"
  value       = aws_ecr_repository.sample_app.repository_url
}

output "helm_chart_ecr_repository_url" {
  description = "ECR repository URL used for Helm OCI exercises"
  value       = aws_ecr_repository.helm_chart.repository_url
}

output "oidc_provider_arn" {
  description = "GitHub Actions OIDC provider ARN"
  value       = local.oidc_provider_arn
}

output "oidc_provider_owned_by_course" {
  description = "Whether this Terraform state owns the account-wide OIDC provider"
  value       = var.oidc_provider_mode == "create"
}

output "oidc_ownership_mode" {
  description = "Persisted OIDC ownership mode"
  value       = var.oidc_provider_mode
}
