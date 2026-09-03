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

override_data {
  target = data.terraform_remote_state.eks
  values = {
    outputs = {
      cluster_name                       = "prod-course"
      cluster_endpoint                   = "https://eks.example.invalid"
      cluster_certificate_authority_data = "Y2E="
      oidc_provider_arn                  = "arn:aws:iam::123456789012:oidc-provider/example.invalid"
      oidc_provider                      = "example.invalid"
    }
  }
}

override_data {
  target = data.terraform_remote_state.network
  values = { outputs = { vpc_id = "vpc-0123456789abcdef0" } }
}

variables {
  aws_region                      = "us-east-1"
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
