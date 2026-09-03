mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

run "create_mode_owns_provider" {
  command = plan

  variables {
    aws_region         = "ap-northeast-2"
    oidc_provider_mode = "create"
    state_bucket_arns  = ["arn:aws:s3:::course-state"]
  }

  assert {
    condition     = output.oidc_provider_owned_by_course == true
    error_message = "create mode must report course ownership"
  }
}

run "external_mode_does_not_own_provider" {
  command = plan

  variables {
    aws_region                 = "us-east-1"
    oidc_provider_mode         = "external"
    external_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    state_bucket_arns          = ["arn:aws:s3:::course-state"]
  }

  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "123456789012" }
  }

  override_data {
    target = data.aws_iam_openid_connect_provider.external[0]
    values = {
      arn            = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
      url            = "token.actions.githubusercontent.com"
      client_id_list = ["sts.amazonaws.com"]
    }
  }

  assert {
    condition     = output.oidc_provider_owned_by_course == false
    error_message = "external mode must not report course ownership"
  }
}
