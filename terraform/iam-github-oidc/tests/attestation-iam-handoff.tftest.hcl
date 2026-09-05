mock_provider "aws" {
  mock_data "aws_iam_policy_document" { defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::123456789012:role/fixture" } }
  mock_resource "aws_iam_policy" { defaults = { arn = "arn:aws:iam::123456789012:policy/fixture" } }
  mock_resource "aws_ecr_repository" { defaults = { arn = "arn:aws:ecr:ap-northeast-2:123456789012:repository/fixture", repository_url = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/fixture" } }
}
variables {
  aws_region = "ap-northeast-2"
  tags       = { PlatformInstanceId = "fixture", Owner = "fixture", CostCenter = "fixture" }
}
run "attestation_role_is_separate_and_exact" {
  command = apply
  override_resource {
    target = aws_iam_role.sample_app_push
    values = { arn = "arn:aws:iam::123456789012:role/build" }
  }
  override_resource {
    target = aws_iam_role.sample_app_attest_verify
    values = { arn = "arn:aws:iam::123456789012:role/attest" }
  }
  assert {
    condition     = output.sample_app_attest_verify_role_arn == "arn:aws:iam::123456789012:role/attest" && output.sample_app_push_role_arn == "arn:aws:iam::123456789012:role/build"
    error_message = "Role outputs must reference separate managed resources."
  }
  override_resource {
    target = aws_ecr_repository.sample_app
    values = { arn = "arn:aws:ecr:ap-northeast-2:123456789012:repository/playdevops/sample-app" }
  }
  override_resource {
    target = aws_ecr_repository.mini_commerce
    values = { arn = "arn:aws:ecr:ap-northeast-2:123456789012:repository/playdevops/mini-commerce" }
  }
  assert {
    condition     = aws_iam_role.sample_app_attest_verify.name != aws_iam_role.sample_app_push.name && aws_ecr_repository.mini_commerce.image_tag_mutability == "IMMUTABLE" && aws_ecr_repository.mini_commerce_chart.image_tag_mutability == "IMMUTABLE"
    error_message = "Separate role and actual immutable new repositories required."
  }
  assert {
    condition     = toset(jsondecode(aws_iam_policy.sample_app_attest_verify.policy).Statement[1].Action) == toset(["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage"]) && toset(jsondecode(aws_iam_policy.sample_app_attest_verify.policy).Statement[1].Resource) == toset(["arn:aws:ecr:ap-northeast-2:123456789012:repository/playdevops/sample-app", "arn:aws:ecr:ap-northeast-2:123456789012:repository/playdevops/mini-commerce"])
    error_message = "Only exact old/new image read/referrer/write permissions are valid."
  }
  assert {
    condition     = jsondecode(aws_iam_role.sample_app_attest_verify.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com" && toset(jsondecode(aws_iam_role.sample_app_attest_verify.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"]) == toset(["repo:play-builder@42942042/cicd-course-sample-app@1352247019:ref:refs/heads/main", "repo:play-builder@42942042/mini-commerce@1352247019:ref:refs/heads/main"])
    error_message = "Trust must be numeric old/new exact main only."
  }
}
run "rejects_wildcard_subject" {
  command = plan
  variables { sample_app_attest_verify_oidc_subjects = ["repo:*"] }
  expect_failures = [var.sample_app_attest_verify_oidc_subjects]
}
run "rejects_wrong_numeric_subject" {
  command = plan
  variables { sample_app_attest_verify_oidc_subjects = ["repo:play-builder@42942042/mini-commerce@111111:ref:refs/heads/main"] }
  expect_failures = [var.sample_app_attest_verify_oidc_subjects]
}
run "rejects_shared_role_name" {
  command = plan
  variables { sample_app_attest_verify_role_name = "playdevops-github-sample-app-push" }
  expect_failures = [var.sample_app_attest_verify_role_name]
}
