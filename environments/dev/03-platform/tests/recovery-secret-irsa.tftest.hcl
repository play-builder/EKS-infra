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
      domain_validation_options = [{
        domain_name           = "dev.example.com"
        resource_record_name  = "_validation.dev.example.com"
        resource_record_type  = "CNAME"
        resource_record_value = "_token.acm-validations.aws"
      }]
    }
  }

  mock_resource "aws_secretsmanager_secret" {
    override_during = plan
    defaults = {
      arn = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:sample-app/dev/sample-app-db-AbCdEf"
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
      cluster_name                       = "dev-course"
      cluster_endpoint                   = "https://eks.example.invalid"
      cluster_certificate_authority_data = "Y2E="
      oidc_provider_arn                  = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/EXAMPLE"
      oidc_provider                      = "oidc.eks.ap-northeast-2.amazonaws.com/id/EXAMPLE"
    }
  }
}

override_data {
  target = data.terraform_remote_state.network
  values = { outputs = { vpc_id = "vpc-0123456789abcdef0" } }
}

variables {
  aws_region                      = "ap-northeast-2"
  acm_domain_name                 = "dev.example.com"
  hosted_zone_id                  = "Z0123456789"
  enable_gateway_api              = false
  enable_course_storage_class     = false
  enable_ebs_csi_driver           = false
  enable_alb_controller           = false
  enable_external_dns             = false
  enable_metrics_server           = false
  enable_adot_collector           = false
  enable_amp                      = false
  enable_external_secrets         = false
  external_secrets_ownership_mode = "fresh"
  enable_recovery_secret_reader   = true
  recovery_secret_kms_key_arn     = "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-2222-3333-4444-555555555555"
}

run "recovery_role_is_namespace_and_secret_scoped" {
  command = plan

  assert {
    condition = (
      jsondecode(aws_iam_role.recovery_db_secret_reader[0].assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.ap-northeast-2.amazonaws.com/id/EXAMPLE:sub"] == "system:serviceaccount:app-recovery:sample-app-recovery-secret-reader" &&
      jsondecode(aws_iam_role.recovery_db_secret_reader[0].assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.ap-northeast-2.amazonaws.com/id/EXAMPLE:aud"] == "sts.amazonaws.com"
    )
    error_message = "The recovery role trust must name only the recovery ServiceAccount subject."
  }

  assert {
    condition = (
      jsondecode(aws_iam_policy.recovery_db_secret_reader[0].policy).Statement[0].Action == ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue"] &&
      jsondecode(aws_iam_policy.recovery_db_secret_reader[0].policy).Statement[0].Resource == [aws_secretsmanager_secret.sample_app_db[0].arn] &&
      jsondecode(aws_iam_policy.recovery_db_secret_reader[0].policy).Statement[1].Action == ["kms:Decrypt"] &&
      jsondecode(aws_iam_policy.recovery_db_secret_reader[0].policy).Statement[1].Resource == ["arn:aws:kms:ap-northeast-2:123456789012:key/11111111-2222-3333-4444-555555555555"] &&
      !strcontains(aws_iam_policy.recovery_db_secret_reader[0].policy, "sample-app-runtime") &&
      !strcontains(aws_iam_policy.recovery_db_secret_reader[0].policy, "\"Resource\":\"*\"")
    )
    error_message = "The recovery role must read only the DB secret and optional exact CMK."
  }
}
