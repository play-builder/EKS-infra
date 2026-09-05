data "terraform_remote_state" "network" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = "prod/01-network/terraform.tfstate", region = var.state_region, allowed_account_ids = [var.expected_account_id] }
}
data "terraform_remote_state" "platform" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = "prod/03-platform/terraform.tfstate", region = var.state_region, allowed_account_ids = [var.expected_account_id] }
}

locals {
  credentials = data.terraform_remote_state.platform.outputs.application_credentials
}
data "aws_secretsmanager_secret" "application" {
  for_each = local.credentials
  arn      = each.value.arn
}
resource "terraform_data" "identity" {
  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.expected_account_id && data.aws_region.current.name == var.aws_region && split(":", data.terraform_remote_state.network.outputs.vpc_arn)[4] == var.expected_account_id && split(":", data.terraform_remote_state.network.outputs.vpc_arn)[3] == var.aws_region
      error_message = "Caller, workload Region and source network identity must match."
    }
    precondition {
      condition     = length(setintersection(toset(data.terraform_remote_state.network.outputs.database_subnet_ids), toset(data.terraform_remote_state.network.outputs.private_subnet_ids))) == 0
      error_message = "Database subnets must be distinct from NAT private application subnets."
    }
    precondition {
      condition     = length(local.credentials) == 2 && length(toset([for s in local.credentials : s.arn])) == 2 && alltrue([for k, s in local.credentials : s.arn == data.aws_secretsmanager_secret.application[k].arn && s.name == data.aws_secretsmanager_secret.application[k].name && startswith(s.arn, "arn:aws:secretsmanager:${var.aws_region}:${var.expected_account_id}:secret:")])
      error_message = "Use distinct existing secret shells in the exact account and Region."
    }

  }
}
module "database" {
  source                    = "../../../modules/database/rds-postgresql"
  depends_on                = [terraform_data.identity]
  identifier                = var.identifier
  vpc_id                    = data.terraform_remote_state.network.outputs.vpc_id
  subnet_ids                = data.terraform_remote_state.network.outputs.database_subnet_ids
  client_security_group_ids = var.client_security_group_ids
  engine_version            = var.engine_version
  instance_class            = var.instance_class
  ca_cert_identifier        = var.ca_cert_identifier
  database_name             = var.database_name
  backup_retention_days     = var.backup_retention_days
  max_allocated_storage     = var.max_allocated_storage
  deletion_protection       = var.deletion_protection
  final_snapshot_identifier = var.final_snapshot_identifier
  recovery_objectives       = var.recovery_objectives
  tags                      = var.tags

}
