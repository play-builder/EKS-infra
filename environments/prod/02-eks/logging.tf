data "aws_caller_identity" "logging" {}
resource "terraform_data" "logging_identity" {
  input = local.cluster_name
  lifecycle {
    precondition {
      condition     = local.cluster_name == data.terraform_remote_state.network.outputs.logging_contract.cluster_name && var.aws_region == data.terraform_remote_state.network.outputs.logging_contract.aws_region && data.aws_caller_identity.logging.account_id == data.terraform_remote_state.network.outputs.logging_contract.account_id
      error_message = "EKS name/Region must match the precomputed network log-key contract."
    }
  }
}
output "audit_log_groups" {
  value = merge(data.terraform_remote_state.network.outputs.audit_log_groups, module.eks_cluster.audit_log_groups)
}
output "logging_contract" { value = data.terraform_remote_state.network.outputs.logging_contract }
