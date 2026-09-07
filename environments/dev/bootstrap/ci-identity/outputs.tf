output "oidc_provider_arn" {
  value = local.oidc_provider_arn
}

output "infra_role_arn" {
  description = "Role GitHub Actions assumes to run Terraform in this account"
  value       = aws_iam_role.infra.arn
}

output "trusted_subject" {
  value = local.infra_main_subject
}
