output "database_contract" {
  value = merge(module.database.database_contract, {
    applicationCredentials = local.credentials
    root                   = { stateBucket = var.state_bucket, stateRegion = var.state_region, stateKey = "prod/03-database/terraform.tfstate", environment = "prod" }
  })
}
