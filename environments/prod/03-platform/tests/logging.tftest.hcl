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

mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "http" {}
variables {
  state_bucket_name            = "course-state"
  aws_region                   = "ap-northeast-2"
  acm_domain_name              = "example.invalid"
  hosted_zone_id               = "Z1234"
  enable_course_resources      = false
  enable_gateway_api           = false
  enable_container_insights    = true
  enable_cluster_autoscaler    = true
  enable_amp                   = false
  enable_adot_collector        = false
  enable_amg                   = false
  enable_ebs_csi_driver        = false
  enable_alb_controller        = false
  enable_external_dns          = false
  enable_metrics_server        = false
  sigstore_ecr_repository_arns = []
  sigstore_api_server_cidrs    = []
  sigstore_https_egress_cidrs  = []
  autoscaler_capacity = {
    min_nodes = 2, max_nodes = 6, max_pods_per_node = 29, hpa_max_replicas = 10, rollout_surge_replicas = 2, platform_reserve_pods = 10, stable_replicas = 3, canary_replicas = 1, usable_subnet_ips_by_az = { a = 200, b = 200, c = 200 }, required_headroom_percentage = 20
  }
}
override_data {
  target = data.terraform_remote_state.network
  values = { outputs = { vpc_id = "vpc-0123456789abcdef0", logging_contract = {
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
    }, audit_log_groups = {
    control_plane = { arn = "arn:aws:logs:ap-northeast-2:123456789012:log-group:/aws/eks/prod-playdevops-eks/cluster", retention_days = 90, kms_key_arn = "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-2222-3333-4444-555555555555" }
    vpc_flow      = { arn = "arn:aws:logs:ap-northeast-2:123456789012:log-group:/aws/vpc/prod-playdevops/flow-logs", retention_days = 90, kms_key_arn = "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-2222-3333-4444-555555555555" }
  } } }
}
override_data {
  target = data.terraform_remote_state.eks
  values = { outputs = {
    cluster_name                       = "prod-playdevops-eks"
    cluster_arn                        = "arn:aws:eks:ap-northeast-2:123456789012:cluster/prod-playdevops-eks"
    cluster_endpoint                   = "https://example.invalid"
    cluster_certificate_authority_data = "Y2E="
    oidc_provider_arn                  = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/EXAMPLE"
    oidc_provider                      = "oidc.eks.ap-northeast-2.amazonaws.com/id/EXAMPLE"
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
  target  = module.acm
  outputs = { acm_certificate_arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/test" }
}
override_module {
  target  = module.cluster_autoscaler
  outputs = { capacity_contract = {} }
}
override_module {
  target  = module.sigstore_policy_controller
  outputs = { sigstore_controller = {} }
}
override_module {
  target  = module.mini_commerce_secrets
  outputs = { secrets = {}, application_credentials = {} }
}
override_module {
  target  = module.external_secrets
  outputs = { helm_release = "fixture", namespace = "external-secrets", chart_version = "fixture", release_name = "external-secrets" }
}
override_module {
  target  = module.k6_operator
  outputs = { enabled = false, namespace = "k6", chart_version = "fixture" }
}
override_module {
  target  = module.amp_alerting
  outputs = { enabled = false, sns_topic_arn = null }
}
run "platform_exports_five_protected_planes" {
  command = apply
  assert {
    condition     = toset(keys(output.audit_log_groups)) == toset(["control_plane", "vpc_flow", "application", "performance", "waf"]) && alltrue([for group in output.audit_log_groups : group.kms_key_arn == "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-2222-3333-4444-555555555555"]) && output.audit_log_groups.application.retention_days == 90 && output.audit_log_groups.performance.retention_days == 90 && output.audit_log_groups.waf.retention_days == 90 && output.waf_log_group_arn == "arn:aws:logs:ap-northeast-2:123456789012:log-group:aws-waf-logs-prod-playdevops"
    error_message = "Platform must export every independent log plane using the network-owned KMS key."
  }
}
run "prod_cannot_disable_log_collectors" {
  command = plan
  variables { enable_container_insights = false }
  expect_failures = [var.enable_container_insights]
}

run "different_provider_account_is_rejected" {
  command = plan
  override_data {
    target = data.aws_caller_identity.logging
    values = { account_id = "999999999999" }
  }
  expect_failures = [terraform_data.logging_identity]
}
