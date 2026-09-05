mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { name = "ap-northeast-2" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/test" }
  }
}
override_resource {
  target = aws_iam_role.cloudwatch_agent
  values = { arn = "arn:aws:iam::123456789012:role/platform-prod-container-insights-role" }
}
override_resource {
  target = aws_iam_role.fluent_bit
  values = { arn = "arn:aws:iam::123456789012:role/platform-prod-fluent-bit-role" }
}
mock_provider "kubernetes" {}
mock_provider "helm" {}
variables {
  eks_cluster_name           = "platform-prod"
  aws_region                 = "ap-northeast-2"
  environment                = "prod"
  account_id                 = "123456789012"
  kms_key_arn                = "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-2222-3333-4444-555555555555"
  application_retention_days = 90
  performance_retention_days = 90
  oidc_provider_arn          = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/EXAMPLE"
  oidc_provider              = "oidc.eks.ap-northeast-2.amazonaws.com/id/EXAMPLE"
  tags                       = { PlatformInstanceId = "platform", Owner = "team", CostCenter = "test", Environment = "prod" }
}
run "reject_short_performance_retention" {
  command = plan
  variables { performance_retention_days = 30 }
  expect_failures = [var.performance_retention_days]
}
run "reject_unsupported_application_retention" {
  command = plan
  variables { application_retention_days = 91 }
  expect_failures = [var.application_retention_days]
}
run "reject_cross_account_oidc" {
  command = plan
  variables { oidc_provider_arn = "arn:aws:iam::999999999999:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/EXAMPLE" }
  expect_failures = [var.oidc_provider_arn]
}
run "fluent_bit_must_use_precreated_group" {
  command = apply
  assert {
    condition     = yamldecode(helm_release.fluent_bit.values[0]).cloudWatchLogs.autoCreateGroup == false
    error_message = "Fluent Bit must not auto-create unencrypted unretained groups."
  }
}

run "render_separate_workload_identity_and_log_permissions" {
  command = apply
  assert {
    condition     = jsondecode(aws_iam_role.cloudwatch_agent.assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.ap-northeast-2.amazonaws.com/id/EXAMPLE:sub"] == "system:serviceaccount:amazon-cloudwatch:cloudwatch-agent" && jsondecode(aws_iam_role.fluent_bit.assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.ap-northeast-2.amazonaws.com/id/EXAMPLE:sub"] == "system:serviceaccount:amazon-cloudwatch:fluent-bit" && jsondecode(aws_iam_role.fluent_bit.assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.ap-northeast-2.amazonaws.com/id/EXAMPLE:aud"] == "sts.amazonaws.com"
    error_message = "Agent and Fluent Bit require exact separate ServiceAccount trust plus STS audience."
  }
  assert {
    condition     = yamldecode(helm_release.fluent_bit.values[0]).serviceAccount.name == "fluent-bit" && yamldecode(helm_release.fluent_bit.values[0]).serviceAccount.annotations["eks.amazonaws.com/role-arn"] == aws_iam_role.fluent_bit.arn && yamldecode(helm_release.cloudwatch_agent.values[0]).serviceAccount.annotations["eks.amazonaws.com/role-arn"] == aws_iam_role.cloudwatch_agent.arn
    error_message = "Each Helm ServiceAccount must bind to its matching role."
  }
  assert {
    condition     = alltrue([for s in concat(jsondecode(aws_iam_policy.cloudwatch_agent.policy).Statement, jsondecode(aws_iam_policy.fluent_bit.policy).Statement) : !contains(s.Action, "logs:CreateLogGroup")]) && toset(jsondecode(aws_iam_policy.fluent_bit.policy).Statement[0].Resource) == toset(["arn:aws:logs:ap-northeast-2:123456789012:log-group:/aws/containerinsights/platform-prod/application:log-stream:*"]) && toset(jsondecode(aws_iam_policy.cloudwatch_agent.policy).Statement[0].Resource) == toset(["arn:aws:logs:ap-northeast-2:123456789012:log-group:/aws/containerinsights/platform-prod/performance:log-stream:*"])
    error_message = "Agents may write only their own precreated log streams and cannot create groups."
  }
  assert {
    condition     = jsondecode(aws_iam_policy.fluent_bit.policy).Statement[2].Condition.StringEquals["kms:ViaService"] == "logs.ap-northeast-2.amazonaws.com" && jsondecode(aws_iam_policy.fluent_bit.policy).Statement[2].Condition.ArnEquals["kms:EncryptionContext:aws:logs:arn"] == "arn:aws:logs:ap-northeast-2:123456789012:log-group:/aws/containerinsights/platform-prod/application"
    error_message = "Agent KMS access must bind regional Logs service and its own group."
  }
  assert {
    condition     = length(aws_cloudwatch_log_group.this) == 2 && alltrue([for g in aws_cloudwatch_log_group.this : g.kms_key_id == var.kms_key_arn && g.retention_in_days == 90]) && yamldecode(helm_release.fluent_bit.values[0]).cloudWatchLogs.logGroupName == "/aws/containerinsights/platform-prod/application"
    error_message = "Both application and performance groups must be encrypted and retained before installation."
  }
}
run "reject_provider_region_mismatch" {
  command = plan
  variables {
    aws_region        = "us-east-1"
    kms_key_arn       = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    oidc_provider     = "oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE"
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/EXAMPLE"
  }
  expect_failures = [var.aws_region]
}

run "default_owner_is_terraform" {
  command = plan
  assert {
    condition     = try(aws_cloudwatch_log_group.this["application"].tags.ManagedBy, "") == "Terraform" && try(aws_cloudwatch_log_group.this["performance"].tags.ManagedBy, "") == "Terraform" && try(aws_iam_role.cloudwatch_agent.tags.ManagedBy, "") == "Terraform" && try(aws_iam_policy.cloudwatch_agent.tags.ManagedBy, "") == "Terraform" && try(aws_iam_role.fluent_bit.tags.ManagedBy, "") == "Terraform" && try(aws_iam_policy.fluent_bit.tags.ManagedBy, "") == "Terraform"
    error_message = "All owned taggable resources must resolve ManagedBy=Terraform when caller omits it."
  }
}
run "caller_cannot_override_terraform_owner" {
  command = plan
  variables {
    tags = { PlatformInstanceId = "platform", Owner = "team", CostCenter = "test", Environment = "prod", ManagedBy = "Other" }
  }
  assert {
    condition     = try(aws_cloudwatch_log_group.this["application"].tags.ManagedBy, "") == "Terraform" && try(aws_cloudwatch_log_group.this["performance"].tags.ManagedBy, "") == "Terraform" && try(aws_iam_role.cloudwatch_agent.tags.ManagedBy, "") == "Terraform" && try(aws_iam_policy.cloudwatch_agent.tags.ManagedBy, "") == "Terraform" && try(aws_iam_role.fluent_bit.tags.ManagedBy, "") == "Terraform" && try(aws_iam_policy.fluent_bit.tags.ManagedBy, "") == "Terraform"
    error_message = "Caller ManagedBy cannot override Terraform resource ownership."
  }
}
