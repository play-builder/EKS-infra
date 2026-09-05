data "aws_caller_identity" "logging" {}
variable "application_log_retention_in_days" {
  type    = number
  default = 90
}
variable "performance_log_retention_in_days" {
  type    = number
  default = 90
}
variable "waf_log_retention_in_days" {
  type    = number
  default = 90
}
variable "waf_rate_limit" {
  type    = number
  default = 2000
}
resource "terraform_data" "logging_identity" {
  input = local.eks_cluster_name
  lifecycle {
    precondition {
      condition     = local.eks_cluster_name == data.terraform_remote_state.network.outputs.logging_contract.cluster_name && var.aws_region == data.terraform_remote_state.network.outputs.logging_contract.aws_region && data.aws_caller_identity.logging.account_id == data.terraform_remote_state.network.outputs.logging_contract.account_id && data.terraform_remote_state.eks.outputs.logging_contract == data.terraform_remote_state.network.outputs.logging_contract
      error_message = "Platform requires matching network and EKS log-plane contracts."
    }
  }
}
module "waf" {
  source         = "../../../modules/security/waf-web-acl"
  name           = data.terraform_remote_state.network.outputs.logging_contract.waf_name
  environment    = var.environment
  account_id     = data.terraform_remote_state.network.outputs.logging_contract.account_id
  aws_region     = var.aws_region
  kms_key_arn    = data.terraform_remote_state.network.outputs.logging_contract.kms_key_arn
  retention_days = var.waf_log_retention_in_days
  rate_limit     = var.waf_rate_limit
  tags           = local.common_tags
  depends_on     = [terraform_data.logging_identity]
}
output "web_acl_arn" { value = module.waf.web_acl_arn }
output "waf_log_group_arn" { value = module.waf.log_group_arn }
output "audit_log_groups" {
  value = merge(
    data.terraform_remote_state.eks.outputs.audit_log_groups,
    var.enable_container_insights ? module.container_insights[0].audit_log_groups : {},
    module.waf.audit_log_groups
  )
}
output "audit_log_protection" {
  value = {
    kms_key_arn = data.terraform_remote_state.network.outputs.logging_contract.kms_key_arn
    groups      = merge(data.terraform_remote_state.eks.outputs.audit_log_groups, var.enable_container_insights ? module.container_insights[0].audit_log_groups : {}, module.waf.audit_log_groups)
  }
}
