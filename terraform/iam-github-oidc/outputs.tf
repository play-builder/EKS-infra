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
  value       = aws_iam_openid_connect_provider.github.arn
}

