mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

run "provider_mode_is_an_explicit_ownership_decision" {
  command = plan
  variables {
    aws_region         = "ap-northeast-2"
    oidc_provider_mode = "create"
  }

  assert {
    condition     = output.oidc_ownership_mode == "create"
    error_message = "ownership mode must be persisted as an output"
  }
}
