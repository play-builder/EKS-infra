# Real provider renders IAM policy JSON locally. Every remote data read is overridden;
# all runs are plans, with dummy credentials and credential/metadata requests disabled.
provider "aws" {
  region                      = "ap-northeast-2"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
}

override_data {
  target = data.aws_caller_identity.current
  values = { account_id = "123456789012" }
}
override_resource {
  target          = aws_iam_openid_connect_provider.github
  override_during = plan
  values          = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
}
override_data {
  target = data.aws_iam_openid_connect_provider.external
  values = {
    arn            = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    url            = "token.actions.githubusercontent.com"
    client_id_list = ["sts.amazonaws.com"]
  }
}
override_data {
  target = module.registry_scanning.data.aws_caller_identity.current
  values = { account_id = "123456789012" }
}
override_resource {
  target          = aws_ecr_repository.image
  override_during = plan
  values          = { arn = "arn:aws:ecr:ap-northeast-2:123456789012:repository/mini-commerce" }
}
override_resource {
  target          = aws_ecr_repository.chart
  override_during = plan
  values          = { arn = "arn:aws:ecr:ap-northeast-2:123456789012:repository/mini-commerce-chart" }
}
override_resource {
  target          = aws_ecr_repository.platform
  override_during = plan
  values = {
    arn            = "arn:aws:ecr:ap-northeast-2:123456789012:repository/platform/istio-proxy"
    repository_url = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/platform/istio-proxy"
  }
}
variables {
  aws_region        = "ap-northeast-2"
  org_id            = "o-1234567890"
  github_owner      = "fixture-owner"
  github_owner_id   = "12345"
  app_repository_id = "67890"
}
run "disabled_publisher_preserves_external_scanning" {
  command = plan
  assert {
    condition     = length(aws_ecr_repository.platform) == 0 && length(aws_iam_role.platform_publisher) == 0 && output.registry_scanning_contract.ownerMode == "external" && !output.registry_scanning_contract.liveVerified
    error_message = "Default must create no publisher or registry scanning singleton."
  }
}
run "dedicated_publisher" {
  command = plan
  variables {
    platform_image_publisher = {
      github_owner        = "fixture-owner"
      github_owner_id     = "12345"
      repository_name     = "EKS-infra"
      repository_id       = "45678"
      ecr_repository_name = "platform/istio-proxy"
    }
  }
  assert {
    condition     = output.platform_image_publisher_trusted_subject == "repo:fixture-owner@12345/EKS-infra@45678:environment:production" && jsondecode(aws_iam_role.platform_publisher["platform"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == output.platform_image_publisher_trusted_subject
    error_message = "Publisher must trust the exact infra repository production environment, not app main."
  }
  assert {
    condition     = data.aws_iam_policy_document.platform_publish["platform"].statement[1].resources == toset(["arn:aws:ecr:ap-northeast-2:123456789012:repository/platform/istio-proxy"]) && aws_ecr_repository.platform["platform"].image_tag_mutability == "IMMUTABLE" && !aws_ecr_repository.platform["platform"].force_delete && contains(output.registry_scanning_contract.requiredRepositories, "platform/istio-proxy")
    error_message = "Publisher must write only its immutable private mirror repository and declare scanning coverage."
  }
  assert {
    condition     = !contains(data.aws_iam_policy_document.image_push.statement[1].resources, aws_ecr_repository.platform["platform"].arn)
    error_message = "Application publisher must not acquire platform publication permission."
  }
}
run "rejects_zero_publisher_identity" {
  command = plan
  variables {
    platform_image_publisher = {
      github_owner        = "fixture-owner"
      github_owner_id     = "0"
      repository_name     = "EKS-infra"
      repository_id       = "0"
      ecr_repository_name = "platform/istio-proxy"
    }
  }
  expect_failures = [var.platform_image_publisher]
}
run "valid_external_oidc" {
  command = plan
  variables {
    oidc_provider_mode         = "external"
    external_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  }
  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "External provider must remain externally owned."
  }
}
run "rejects_external_oidc_without_sts_audience" {
  command = plan
  variables {
    oidc_provider_mode         = "external"
    external_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  }
  override_data {
    target = data.aws_iam_openid_connect_provider.external
    values = {
      arn            = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
      url            = "token.actions.githubusercontent.com"
      client_id_list = ["unexpected.example"]
    }
  }
  expect_failures = [data.aws_iam_openid_connect_provider.external]
}
