data "aws_caller_identity" "logging" {}
variable "cluster_name" {
  description = "Planned EKS name, shared with 02-eks. Null uses environment-project-eks."
  type        = string
  default     = null
}
variable "log_key_administrator_role_arns" {
  description = "Existing same-account roles, including the Terraform execution role."
  type        = set(string)
}
variable "log_reader_role_arns" {
  description = "Optional exact approved log API reader role ARNs."
  type        = set(string)
  default     = []
}
variable "platform_instance_id" { type = string }
variable "owner" { type = string }
variable "cost_center" { type = string }
variable "enable_vpc_flow_logs" {
  type    = bool
  default = true
}
variable "vpc_flow_log_retention_in_days" {
  type    = number
  default = 30
}

locals {
  logging_group_names = {
    control_plane = "/aws/eks/${local.eks_cluster_name}/cluster"
    vpc_flow      = "/aws/vpc/${local.name}/flow-logs"
    application   = "/aws/containerinsights/${local.eks_cluster_name}/application"
    performance   = "/aws/containerinsights/${local.eks_cluster_name}/performance"
    waf           = "aws-waf-logs-${local.name}"
  }
}
module "log_key" {
  source                  = "../../../modules/security/log-key"
  name                    = local.name
  environment             = var.environment
  account_id              = data.aws_caller_identity.logging.account_id
  aws_region              = var.aws_region
  administrator_role_arns = var.log_key_administrator_role_arns
  caller_role_arns = setunion(var.log_reader_role_arns, toset([
    "arn:aws:iam::${data.aws_caller_identity.logging.account_id}:role/${local.name}-vpc-flow-logs",
    "arn:aws:iam::${data.aws_caller_identity.logging.account_id}:role/${local.eks_cluster_name}-container-insights-role",
    "arn:aws:iam::${data.aws_caller_identity.logging.account_id}:role/${local.eks_cluster_name}-fluent-bit-role"
  ]))
  log_group_names = toset(values(local.logging_group_names))
  tags            = local.common_tags
}
output "logging_contract" {
  value = {
    kms_key_arn     = module.log_key.kms_key_arn
    cluster_name    = local.eks_cluster_name
    waf_name        = local.name
    account_id      = data.aws_caller_identity.logging.account_id
    aws_region      = var.aws_region
    log_group_names = local.logging_group_names
    platform_tags   = local.common_tags
  }
}
output "audit_log_groups" { value = module.vpc.audit_log_groups }
