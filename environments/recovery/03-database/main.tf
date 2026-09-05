data "terraform_remote_state" "network" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = "prod/01-network/terraform.tfstate", region = var.state_region, allowed_account_ids = [var.expected_account_id] }
}
data "terraform_remote_state" "platform" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = "prod/03-platform/terraform.tfstate", region = var.state_region, allowed_account_ids = [var.expected_account_id] }
}
data "terraform_remote_state" "source" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = "prod/03-database/terraform.tfstate", region = var.state_region, allowed_account_ids = [var.expected_account_id] }
}
data "terraform_remote_state" "source_cluster" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = "prod/02-eks/terraform.tfstate", region = var.state_region, allowed_account_ids = [var.expected_account_id] }
}
data "aws_eks_cluster" "recovery" { name = var.recovery_cluster_name }
data "aws_iam_openid_connect_provider" "recovery" {
  url = data.aws_eks_cluster.recovery.identity[0].oidc[0].issuer
}
locals {
  credentials   = module.recovery_secrets.application_credentials
  recovery_oidc = trimprefix(data.aws_eks_cluster.recovery.identity[0].oidc[0].issuer, "https://")
}
module "recovery_secrets" {
  source            = "../../../modules/security/mini-commerce-secrets"
  depends_on        = [terraform_data.identity]
  name              = "recovery-${var.identifier}"
  namespace         = "app-recovery"
  region            = var.aws_region
  oidc_provider     = local.recovery_oidc
  oidc_provider_arn = data.aws_iam_openid_connect_provider.recovery.arn
  tags              = merge(local.owned_tags, { ManagedBy = "Terraform", RecoveryTarget = var.identifier })
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
      condition     = data.aws_eks_cluster.recovery.arn == "arn:aws:eks:${var.aws_region}:${var.expected_account_id}:cluster/${var.recovery_cluster_name}" && data.aws_eks_cluster.recovery.arn != data.terraform_remote_state.source_cluster.outputs.cluster_arn && local.recovery_oidc != data.terraform_remote_state.source_cluster.outputs.oidc_provider && data.aws_iam_openid_connect_provider.recovery.arn == "arn:aws:iam::${var.expected_account_id}:oidc-provider/${local.recovery_oidc}"
      error_message = "Recovery secret readers require a distinct actual recovery cluster and its same-account OIDC provider."
    }
    precondition {
      condition     = data.terraform_remote_state.source.outputs.database_contract.schemaVersion == "platform.database/v1" && data.terraform_remote_state.source.outputs.database_contract.accountId == var.expected_account_id && data.terraform_remote_state.source.outputs.database_contract.region == var.aws_region && data.terraform_remote_state.source.outputs.database_contract.identifier != var.identifier && data.terraform_remote_state.source.outputs.database_contract.root.stateKey == "prod/03-database/terraform.tfstate" && data.terraform_remote_state.source.outputs.database_contract.root.stateBucket == var.state_bucket
      error_message = "Recovery requires an identified production source in a different Terraform state."
    }
    precondition {
      condition     = alltrue([for k, s in data.terraform_remote_state.platform.outputs.application_credentials : s.name != "recovery-${var.identifier}/mini-commerce/${k}"])
      error_message = "Recovery secret names must be distinct from production secret shells."
    }
  }
}
module "database" {
  source                            = "../../../modules/database/rds-postgresql"
  depends_on                        = [terraform_data.identity]
  identifier                        = var.identifier
  vpc_id                            = data.terraform_remote_state.network.outputs.vpc_id
  subnet_ids                        = data.terraform_remote_state.network.outputs.database_subnet_ids
  client_security_group_ids         = var.client_security_group_ids
  engine_version                    = var.engine_version
  instance_class                    = var.instance_class
  ca_cert_identifier                = var.ca_cert_identifier
  database_name                     = var.database_name
  backup_retention_days             = var.backup_retention_days
  max_allocated_storage             = var.max_allocated_storage
  deletion_protection               = var.deletion_protection
  final_snapshot_identifier         = var.final_snapshot_identifier
  recovery_objectives               = var.recovery_objectives
  tags                              = local.owned_tags
  restore_to_point_in_time          = { source_db_instance_identifier = data.terraform_remote_state.source.outputs.database_contract.identifier, restore_time = var.restore_time }
  apply_restore_changes_immediately = var.apply_restore_changes_immediately
}
