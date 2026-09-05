mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

run "state_and_lock_objects_have_distinct_minimum_permissions" {
  command = plan

  variables {
    aws_region = "ap-northeast-2"
    state_bucket_arns = [
      "arn:aws:s3:::course-dev-state",
      "arn:aws:s3:::course-prod-state",
    ]
  }

  assert {
    condition = toset([
      for statement in jsondecode(aws_iam_policy.infra.policy).Statement : statement.Resource
      if statement.Sid == "TerraformStateBucketList"
    ][0]) == toset(var.state_bucket_arns)
    error_message = "ListBucket must be scoped to the explicit state bucket ARN set"
  }

  assert {
    condition = toset([
      for statement in jsondecode(aws_iam_policy.infra.policy).Statement : statement.Action
      if statement.Sid == "TerraformStateBucketList"
    ][0]) == toset(["s3:ListBucket"])
    error_message = "bucket access must allow only ListBucket"
  }

  assert {
    condition = toset([
      for statement in jsondecode(aws_iam_policy.infra.policy).Statement : statement.Action
      if statement.Sid == "TerraformStateObjects"
    ][0]) == toset(["s3:GetObject", "s3:PutObject"])
    error_message = "state objects must allow only GetObject and PutObject"
  }

  assert {
    condition = alltrue([
      for resource in [
        for statement in jsondecode(aws_iam_policy.infra.policy).Statement : statement.Resource
        if statement.Sid == "TerraformStateObjects"
      ][0] : endswith(resource, "/terraform.tfstate")
    ])
    error_message = "state object permissions must target exact terraform.tfstate keys"
  }

  assert {
    condition = toset([
      for statement in jsondecode(aws_iam_policy.infra.policy).Statement : statement.Action
      if statement.Sid == "TerraformStateLockObjects"
    ][0]) == toset(["s3:GetObject", "s3:PutObject", "s3:DeleteObject"])
    error_message = "lock objects must allow only GetObject, PutObject, and DeleteObject"
  }

  assert {
    condition = alltrue([
      for resource in [
        for statement in jsondecode(aws_iam_policy.infra.policy).Statement : statement.Resource
        if statement.Sid == "TerraformStateLockObjects"
      ][0] : endswith(resource, "/terraform.tfstate.tflock")
    ])
    error_message = "lock permissions must target only the matching .tflock objects"
  }
}

variables {
  state_bucket_arns = ["arn:aws:s3:::course-state"]
  tags              = { PlatformInstanceId = "fixture", Owner = "fixture", CostCenter = "fixture" }
}
