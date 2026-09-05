mock_provider "aws" {
 mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::123456789012:role/argocd-reader" } }
 mock_resource "aws_secretsmanager_secret" { defaults = { arn = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:fixture-AbCdEf" } }
}
mock_provider "helm" {}
mock_provider "kubectl" {}
variables {
 name = "fixture"
 environment = "prod"
 region = "ap-northeast-2"
 oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/FIXTURE"
 oidc_provider = "oidc.eks.ap-northeast-2.amazonaws.com/id/FIXTURE"
 tags = { PlatformInstanceId = "fixture", Owner = "fixture", CostCenter = "fixture", Environment = "prod" }
 platform = { server_replicas = 2, repo_server_replicas = 2, controller_replicas = 2, applicationset_replicas = 2, redis_ha = true, node_count = 3, az_count = 3, public_url = "https://argocd.example.com", oidc_issuer_url = "https://id.example.com", oidc_client_id = "argocd", admin_group = "platform-admin", readonly_group = "platform-readonly" }
 health_customizations = { "resource.customizations.health.external-secrets.io_ExternalSecret" = "return {status = 'Healthy'}" }
}
run "ha_native_oidc_and_secret_references" {
 command = apply
 assert {
  condition = local.values.dex.enabled == false && local.values["redis-ha"].enabled && local.values.applicationSet.replicas == 2 && local.values.controller.pdb.maxUnavailable == 1
  error_message = "Prod must have native OIDC and HA including applicationSet."
 }
 assert {
  condition = strcontains(local.values.configs.cm["oidc.config"],"$argocd-oidc:clientSecret") && local.values.configs.cm["admin.enabled"] == "true"
  error_message = "Only secret reference enters Helm; bootstrap admin remains available."
 }
 assert {
  condition = toset(jsondecode(aws_iam_role_policy.secret_reader.policy).Statement[0].Action) == toset(["secretsmanager:GetSecretValue","secretsmanager:DescribeSecret"]) && length(jsondecode(aws_iam_role_policy.secret_reader.policy).Statement[0].Resource) == 3
  error_message = "Argo secret reader must be bounded to three secret shells."
 }
}
run "rejects_nonha_prod" {
 command = plan
 variables { platform = { server_replicas = 1, repo_server_replicas = 1, controller_replicas = 1, applicationset_replicas = 1, redis_ha = false, node_count = 2, az_count = 2, public_url = "https://argocd.example.com", oidc_issuer_url = "https://id.example.com", oidc_client_id = "argocd", admin_group = "admin", readonly_group = "reader" } }
 expect_failures = [var.platform]
}
run "dev_can_be_small" {
 command = plan
 variables { environment = "dev" }
 assert {
  condition = output.argocd.bootstrapMode == "public"
  error_message = "Public bootstrap chosen explicitly."
 }
}
