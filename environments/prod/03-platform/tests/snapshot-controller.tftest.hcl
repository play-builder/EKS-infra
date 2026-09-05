mock_provider "aws" {
  mock_data "aws_caller_identity" {
    override_during = plan
    defaults        = { account_id = "123456789012" }
  }

  mock_data "aws_iam_policy_document" {
    override_during = plan
    defaults        = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  mock_resource "aws_acm_certificate" {
    override_during = plan
    defaults = {
      arn = "arn:aws:acm:us-east-1:123456789012:certificate/example"
      domain_validation_options = [{
        domain_name           = "example.com"
        resource_record_name  = "_validation.example.com"
        resource_record_type  = "CNAME"
        resource_record_value = "_token.acm-validations.aws"
      }]
    }
  }
}
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "http" {}



variables {
  enable_cluster_autoscaler       = true
  sigstore_ecr_repository_arns    = []
  sigstore_api_server_cidrs       = []
  sigstore_https_egress_cidrs     = []
  autoscaler_capacity             = { min_nodes = 2, max_nodes = 6, max_pods_per_node = 29, hpa_max_replicas = 10, rollout_surge_replicas = 2, platform_reserve_pods = 10, stable_replicas = 3, canary_replicas = 1, usable_subnet_ips_by_az = { a = 200, b = 200, c = 200 }, required_headroom_percentage = 20 }
  aws_region                      = "us-east-1"
  state_bucket_name               = "course-prod-state"
  acm_domain_name                 = "example.com"
  hosted_zone_id                  = "Z0123456789"
  enable_course_resources         = false
  enable_gateway_api              = false
  enable_ebs_csi_driver           = false
  enable_alb_controller           = false
  enable_external_dns             = false
  enable_metrics_server           = false
  enable_adot_collector           = false
  enable_amp                      = false
  enable_external_secrets         = false
  external_secrets_ownership_mode = "fresh"
}

run "snapshot_resources_are_opt_in" {
  command = plan

  assert {
    condition = (
      length(aws_eks_addon.snapshot_controller) == 0 &&
      length(kubectl_manifest.volume_snapshot_class) == 0
    )
    error_message = "Prod snapshot resources must remain absent unless explicitly enabled."
  }
}

run "explicit_enable_uses_pinned_managed_addon" {
  command = plan

  variables {
    enable_snapshot_controller        = true
    snapshot_controller_addon_version = "v8.2.0-eksbuild.1"
  }

  assert {
    condition = (
      length(aws_eks_addon.snapshot_controller) == 1 &&
      aws_eks_addon.snapshot_controller[0].addon_name == "snapshot-controller" &&
      length(kubectl_manifest.volume_snapshot_class) == 1
    )
    error_message = "An explicit Prod opt-in must create one managed add-on and one class."
  }
}

override_data {
  target = data.terraform_remote_state.network
  values = { outputs = { vpc_id = "vpc-0123456789abcdef0", logging_contract = {
    kms_key_arn  = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    cluster_name = "prod-course"
    waf_name     = "prod-playdevops"
    account_id   = "123456789012"
    aws_region   = "us-east-1"
    log_group_names = {
      control_plane = "/aws/eks/prod-course/cluster"
      vpc_flow      = "/aws/vpc/prod-playdevops/flow-logs"
      application   = "/aws/containerinsights/prod-course/application"
      performance   = "/aws/containerinsights/prod-course/performance"
      waf           = "aws-waf-logs-prod-playdevops"
    }
    platform_tags = { PlatformInstanceId = "platform", Owner = "team", CostCenter = "cc", Environment = "prod", ManagedBy = "Terraform" }
    }, audit_log_groups = {
    control_plane = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/eks/prod-course/cluster", retention_days = 90, kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555" }
    vpc_flow      = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/vpc/prod-playdevops/flow-logs", retention_days = 90, kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555" }
  } } }
}
override_data {
  target = data.terraform_remote_state.eks
  values = { outputs = {
    cluster_name                       = "prod-course"
    cluster_arn                        = "arn:aws:eks:us-east-1:123456789012:cluster/prod-course"
    cluster_endpoint                   = "https://example.invalid"
    cluster_certificate_authority_data = "Y2E="
    oidc_provider_arn                  = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE"
    oidc_provider                      = "oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE"
    logging_contract = {
      kms_key_arn  = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
      cluster_name = "prod-course"
      waf_name     = "prod-playdevops"
      account_id   = "123456789012"
      aws_region   = "us-east-1"
      log_group_names = {
        control_plane = "/aws/eks/prod-course/cluster"
        vpc_flow      = "/aws/vpc/prod-playdevops/flow-logs"
        application   = "/aws/containerinsights/prod-course/application"
        performance   = "/aws/containerinsights/prod-course/performance"
        waf           = "aws-waf-logs-prod-playdevops"
      }
      platform_tags = { PlatformInstanceId = "platform", Owner = "team", CostCenter = "cc", Environment = "prod", ManagedBy = "Terraform" }
    }
    audit_log_groups = {
      control_plane = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/eks/prod-course/cluster", retention_days = 90, kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555" }
      vpc_flow      = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/vpc/prod-playdevops/flow-logs", retention_days = 90, kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555" }
    }
  } }
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
