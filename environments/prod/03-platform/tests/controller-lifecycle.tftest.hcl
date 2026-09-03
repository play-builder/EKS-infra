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
      arn = "arn:aws:acm:ap-northeast-2:123456789012:certificate/example"
      domain_validation_options = [
        {
          domain_name           = "example.com"
          resource_record_name  = "_validation.example.com"
          resource_record_type  = "CNAME"
          resource_record_value = "_token.acm-validations.aws"
        }
      ]
    }
  }

  mock_resource "aws_prometheus_workspace" {
    override_during = plan
    defaults = {
      id                  = "ws-12345678-abcd-1234-abcd-123456789012"
      arn                 = "arn:aws:aps:ap-northeast-2:123456789012:workspace/ws-12345678-abcd-1234-abcd-123456789012"
      prometheus_endpoint = "https://aps-workspaces.ap-northeast-2.amazonaws.com/workspaces/ws-test/"
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
  aws_region                      = "ap-northeast-2"
  acm_domain_name                 = "example.com"
  hosted_zone_id                  = "Z0123456789"
  enable_ebs_csi_driver           = false
  enable_alb_controller           = false
  enable_external_dns             = false
  enable_metrics_server           = false
  enable_adot_collector           = false
  enable_amp                      = false
  enable_gateway_api              = false
  enable_course_storage_class     = false
  external_secrets_ownership_mode = "fresh"
}

run "prod_baseline_has_no_load_controller" {
  command = plan

  assert {
    condition = (
      length(module.external_secrets) == 1 &&
      length(module.reloader) == 0 &&
      module.k6_operator.enabled == false &&
      module.amp_alerting.enabled == false
    )
    error_message = "Prod baseline must not install the course load controller."
  }
}

run "existing_release_requires_adoption_evidence" {
  command = plan

  variables {
    external_secrets_ownership_mode = "adopted"
  }

  expect_failures = [terraform_data.external_secrets_ownership_gate]
}

run "prod_rejects_k6_enablement" {
  command = plan

  variables {
    enable_k6_operator = true
  }

  expect_failures = [var.enable_k6_operator]
}
