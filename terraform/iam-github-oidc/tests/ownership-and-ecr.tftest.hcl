mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_resource "aws_iam_openid_connect_provider" {
    override_during = plan
    defaults = {
      arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    }
  }

  mock_resource "aws_ecr_repository" {
    override_during = plan
    defaults = {
      arn = "arn:aws:ecr:ap-northeast-2:123456789012:repository/playdevops/sample-app"
    }
  }

  mock_resource "aws_iam_role" {
    override_during = plan
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
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

run "supply_chain_role_is_repository_scoped" {
  command = plan

  variables {
    aws_region = "ap-northeast-2"
    state_bucket_arns = [
      "arn:aws:s3:::course-state",
    ]
    sample_app_supply_chain_oidc_subject = "repo:play-builder@42942042/cicd-course-sample-app@1352247019:ref:refs/heads/main"
  }

  assert {
    condition     = output.sample_app_supply_chain_role_arn == aws_iam_role.sample_app_supply_chain.arn
    error_message = "the supply-chain role ARN must be published for AWS_ATTEST_VERIFY_ROLE_ARN"
  }

  assert {
    condition = toset([
      for statement in jsondecode(aws_iam_role.sample_app_supply_chain.assume_role_policy).Statement : statement.Condition.StringEquals["token.actions.githubusercontent.com:sub"]
    ][0]) == toset([var.sample_app_supply_chain_oidc_subject])
    error_message = "the supply-chain role trust must contain only the immutable sample-app main subject"
  }

  assert {
    condition = toset([
      for statement in jsondecode(aws_iam_policy.sample_app_supply_chain.policy).Statement : statement.Action
      if statement.Sid == "EcrLogin"
    ][0]) == toset(["ecr:GetAuthorizationToken"])
    error_message = "only ECR authorization token retrieval may use wildcard resource scope"
  }

  assert {
    condition = [
      for statement in jsondecode(aws_iam_policy.sample_app_supply_chain.policy).Statement : statement.Resource
      if statement.Sid == "EcrLogin"
    ][0] == "*"
    error_message = "ECR authorization token retrieval must use the AWS-required wildcard resource"
  }

  assert {
    condition = toset([
      for statement in jsondecode(aws_iam_policy.sample_app_supply_chain.policy).Statement : statement.Action
      if statement.Sid == "ReadWriteSampleAppOci"
      ][0]) == toset([
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ])
    error_message = "the supply-chain role must have only the required OCI read/write actions"
  }

  assert {
    condition = [
      for statement in jsondecode(aws_iam_policy.sample_app_supply_chain.policy).Statement : statement.Resource
      if statement.Sid == "ReadWriteSampleAppOci"
    ][0] == aws_ecr_repository.sample_app.arn
    error_message = "OCI read/write access must target only the sample-app ECR repository"
  }
}
