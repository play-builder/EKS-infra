output "oidc_provider_arn" {
  value = local.oidc_provider_arn
}

output "registry_url" {
  description = "<account>.dkr.ecr.<region>.amazonaws.com"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}

output "image_repository_name" {
  value = aws_ecr_repository.image.name
}

output "image_repository_url" {
  value = aws_ecr_repository.image.repository_url
}

output "chart_repository_url" {
  value = aws_ecr_repository.chart.repository_url
}

output "image_push_role_arn" {
  description = "GitHub Variables: AWS_ROLE_ARN"
  value       = aws_iam_role.image_push.arn
}

output "attest_verify_role_arn" {
  description = "GitHub Variables: AWS_ATTEST_VERIFY_ROLE_ARN"
  value       = aws_iam_role.attest_verify.arn
}

output "trusted_subject" {
  value = local.app_main_subject
}

output "image_repository_arn" {
  description = "03-platform sigstore_ecr_repository_arns"
  value       = aws_ecr_repository.image.arn
}

output "chart_repository_arn" {
  value = aws_ecr_repository.chart.arn
}

output "aws_region" {
  description = "GitHub Actions Variable AWS_REGION for this registry account."
  value       = var.aws_region
}

output "platform_istio_proxy_repository_url" {
  description = "GitHub Actions Variable PLATFORM_ISTIO_PROXY_REPOSITORY_URL; null while publisher creation is disabled."
  value       = try(aws_ecr_repository.platform["platform"].repository_url, null)
}

output "platform_istio_proxy_repository_arn" {
  description = "Add to the Sigstore controller and workload pull allowlists."
  value       = try(aws_ecr_repository.platform["platform"].arn, null)
}

output "platform_image_publisher_role_arn" {
  description = "GitHub Actions Variable PLATFORM_IMAGE_PUBLISHER_ROLE_ARN."
  value       = try(aws_iam_role.platform_publisher["platform"].arn, null)
}

output "platform_image_publisher_trusted_subject" {
  value = local.platform_subject
}

output "registry_scanning_contract" {
  description = "Required scanning and singleton ownership; external mode does not assert live scanning is enabled."
  value       = module.registry_scanning.contract
}
