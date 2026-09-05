output "github_actions_role_arn" {
  description = "Backward-compatible alias for the EKS-infra role ARN"
  value       = aws_iam_role.infra.arn
}

output "infra_role_arn" {
  description = "EKS-infra GitHub Actions role ARN"
  value       = aws_iam_role.infra.arn
}

output "billing_observer_handoff" {
  description = "CI observer authorization metadata; external plan/apply role policies and billing role trust are operator-owned."
  value = {
    schemaVersion          = "platform.billing-observer-handoff/v1"
    observerRoleArn        = var.billing_monitor_role_arn
    managedWorkloadRoleArn = aws_iam_role.infra.arn
    externalCiRoleSecrets  = ["TERRAFORM_PLAN_ROLE_ARN", "TERRAFORM_APPLY_ROLE_ARN"]
    requiredAction         = "sts:AssumeRole"
    managementProvisioning = false
  }
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
output "sample_app_attest_verify_role_arn" { value = aws_iam_role.sample_app_attest_verify.arn }
output "mini_commerce_ecr_repository_url" { value = aws_ecr_repository.mini_commerce.repository_url }
output "mini_commerce_chart_ecr_repository_url" { value = aws_ecr_repository.mini_commerce_chart.repository_url }
output "mini_commerce_repositories" {
  value = {
    migrationMode = "distinct-repositories"
    legacyImage   = { name = aws_ecr_repository.sample_app.name, arn = aws_ecr_repository.sample_app.arn, url = aws_ecr_repository.sample_app.repository_url }
    image         = { name = aws_ecr_repository.mini_commerce.name, arn = aws_ecr_repository.mini_commerce.arn, url = aws_ecr_repository.mini_commerce.repository_url }
    chart         = { name = aws_ecr_repository.mini_commerce_chart.name, arn = aws_ecr_repository.mini_commerce_chart.arn, url = aws_ecr_repository.mini_commerce_chart.repository_url }
  }
}
output "ecr_scanning" { value = module.ecr_registry_scanning.contract }
