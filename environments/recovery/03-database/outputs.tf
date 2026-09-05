output "database_contract" {
  value = merge(module.database.database_contract, {
    applicationCredentials = local.credentials
    root                   = { stateBucket = var.state_bucket, stateRegion = var.state_region, stateKey = "recovery/03-database/terraform.tfstate", environment = "recovery" }
  })
}
output "recovery_secrets" { value = module.recovery_secrets.secrets }
output "recovery_cluster" {
  value = { arn = data.aws_eks_cluster.recovery.arn, oidcProviderArn = data.aws_iam_openid_connect_provider.recovery.arn, namespace = "app-recovery" }
}
