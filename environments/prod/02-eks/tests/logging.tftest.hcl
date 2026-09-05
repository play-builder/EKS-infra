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
  aws_region                           = "ap-northeast-2"
  cluster_name                         = "prod-playdevops-eks"
  cluster_endpoint_public_access       = false
  cluster_endpoint_public_access_cidrs = []
  vpc_cni_addon_version                = "v1.20.4-eksbuild.1"
  managed_addon_versions               = { coredns = "v1.12.1-eksbuild.1", kube_proxy = "v1.36.0-eksbuild.1" }
  node_release_version                 = "1.36.0-20260901"
  enable_private_node_group            = false
  platform_instance_id                 = "platform"
  owner                                = "team"
  cost_center                          = "cc"
  operator_access                      = { mode = "ssm", trusted_sso_principal_arn = "arn:aws:iam::123456789012:role/aws-reserved/sso.amazonaws.com/ap-northeast-2/AWSReservedSSO_Operator_abc", subnet_id = "subnet-0123456789abcdef0", ami_id = "ami-0123456789abcdef0", instance_type = "t3.micro" }
}
override_data {
  target = data.terraform_remote_state.network
  values = { outputs = {
    vpc_id             = "vpc-0123456789abcdef0"
    public_subnet_ids  = ["subnet-00123456789abcdef"]
    private_subnet_ids = ["subnet-0123456789abcdef0"]
    logging_contract = {
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
    }
    audit_log_groups = {
      control_plane = { arn = "arn:aws:logs:ap-northeast-2:123456789012:log-group:/aws/eks/prod-playdevops-eks/cluster", retention_days = 90, kms_key_arn = "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-2222-3333-4444-555555555555" }
      vpc_flow      = { arn = "arn:aws:logs:ap-northeast-2:123456789012:log-group:/aws/vpc/prod-playdevops/flow-logs", retention_days = 90, kms_key_arn = "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-2222-3333-4444-555555555555" }
    }
  } }
}
override_module {
  target  = module.managed_addons
  outputs = { versions = { coredns = "fixture", kube_proxy = "fixture" }, owner_hash = "fixture" }
}
override_module {
  target  = module.access_entries
  outputs = { access_entries = {}, workload_identity = "IRSA" }
}
override_module {
  target  = module.operator_access
  outputs = { operator_role_arn = "arn:aws:iam::123456789012:role/operator", authorization_namespace = "platform-access", operator_access_status = {} }
}
run "existing_cluster_log_group_consumes_network_key" {
  command = plan
  assert {
    condition     = output.audit_log_groups.control_plane.kms_key_arn == "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-2222-3333-4444-555555555555" && output.audit_log_groups.control_plane.retention_days == 90
    error_message = "Existing EKS log group must consume network key and the independent retention setting."
  }
}
run "different_cluster_name_is_rejected" {
  command = plan
  variables { cluster_name = "wrong-cluster" }
  expect_failures = [terraform_data.logging_identity]
}

run "different_provider_account_is_rejected" {
  command = plan
  override_data {
    target = data.aws_caller_identity.logging
    values = { account_id = "999999999999" }
  }
  expect_failures = [terraform_data.logging_identity]
}
