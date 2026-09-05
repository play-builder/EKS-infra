mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_region" { defaults = { name = "ap-northeast-2" } }
  mock_data "aws_partition" { defaults = { partition = "aws" } }
  mock_resource "aws_kms_key" {
    override_during = plan
    defaults        = { arn = "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-2222-3333-4444-555555555555" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/test" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/test" }
  }
  mock_resource "aws_wafv2_web_acl" {
    defaults = { arn = "arn:aws:wafv2:ap-northeast-2:123456789012:regional/webacl/test/11111111-2222-3333-4444-555555555555" }
  }
}

variables {
  project_name                    = "playdevops"
  environment                     = "prod"
  aws_region                      = "ap-northeast-2"
  platform_instance_id            = "platform"
  owner                           = "team"
  cost_center                     = "cc"
  availability_zones              = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
  vpc_cidr                        = "10.1.0.0/16"
  public_subnet_cidrs             = ["10.1.1.0/24", "10.1.2.0/24", "10.1.3.0/24"]
  private_subnet_cidrs            = ["10.1.11.0/24", "10.1.12.0/24", "10.1.13.0/24"]
  log_key_administrator_role_arns = ["arn:aws:iam::123456789012:role/existing-admin"]
  production_nat_topology         = "per_az"
  single_nat_gateway              = false
  one_nat_gateway_per_az          = true
}
run "five_log_names_and_flow_group_share_owned_key" {
  command = plan
  assert {
    condition = output.logging_contract.log_group_names == {
      kms_key_arn  = "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-2222-3333-4444-555555555555"
      cluster_name = "prod-playdevops-eks"
      waf_name     = "prod-playdevops"
      account_id   = "123456789012"
      aws_region   = "ap-northeast-2"
      log_group_names = {
        control_plane = "/aws/eks/prod-playdevops-eks/cluster"
        vpc_flow      = "/aws/vpc/prod-playdevops/flow-logs"
        application   = "/aws/containerinsights/prod-playdevops-eks/application"
        performance   = "/aws/containerinsights/prod-playdevops-eks/performance"
        waf           = "aws-waf-logs-prod-playdevops"
      }
      platform_tags = { PlatformInstanceId = "platform", Owner = "team", CostCenter = "cc", Environment = "prod", ManagedBy = "Terraform" }
    }.log_group_names && output.logging_contract.kms_key_arn == "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-2222-3333-4444-555555555555" && output.audit_log_groups.vpc_flow.kms_key_arn == "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-2222-3333-4444-555555555555" && output.audit_log_groups.vpc_flow.retention_days == 90
    error_message = "Network must precompute all five names and encrypt Flow Logs with its owned key."
  }
}
run "prod_cannot_disable_flow_logs" {
  command = plan
  variables { enable_vpc_flow_logs = false }
  expect_failures = [var.enable_vpc_flow_logs]
}
