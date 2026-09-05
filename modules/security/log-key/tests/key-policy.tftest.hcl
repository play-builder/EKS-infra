mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { name = "ap-northeast-2" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
}
variables {
  name                    = "platform-prod"
  environment             = "prod"
  account_id              = "123456789012"
  aws_region              = "ap-northeast-2"
  administrator_role_arns = ["arn:aws:iam::123456789012:role/terraform"]
  log_group_names         = ["/aws/eks/platform-prod/cluster"]
  tags                    = { PlatformInstanceId = "platform", Owner = "team", CostCenter = "test", Environment = "prod" }
}
run "reject_wildcard_admin" {
  command = plan
  variables { administrator_role_arns = ["*"] }
  expect_failures = [var.administrator_role_arns]
}
run "reject_group_wildcard" {
  command = plan
  variables { log_group_names = ["/aws/eks/*"] }
  expect_failures = [var.log_group_names]
}

run "reject_external_admin" {
  command = plan
  variables { administrator_role_arns = ["arn:aws:iam::999999999999:role/admin"] }
  expect_failures = [var.administrator_role_arns]
}
run "reject_group_arn_from_wrong_region" {
  command = plan
  variables { log_group_names = ["arn:aws:logs:us-east-1:123456789012:log-group:wrong"] }
  expect_failures = [var.log_group_names]
}
run "reject_blank_tag" {
  command = plan
  variables { tags = { PlatformInstanceId = "platform", Owner = " ", CostCenter = "test", Environment = "prod" } }
  expect_failures = [var.tags]
}
run "render_least_privilege_policy" {
  command = plan
  variables {
    caller_role_arns = ["arn:aws:iam::123456789012:role/platform-prod-fluent-bit-role"]
    log_group_names  = ["/aws/eks/platform-prod/cluster", "/aws/containerinsights/platform-prod/application", "/aws/containerinsights/platform-prod/performance", "/aws/vpc/platform-prod/flow", "aws-waf-logs-platform-prod"]
  }
  assert {
    condition     = aws_kms_key.this.enable_key_rotation && aws_kms_key.this.customer_master_key_spec == "SYMMETRIC_DEFAULT" && !aws_kms_key.this.bypass_policy_lockout_safety_check && aws_kms_key.this.deletion_window_in_days == 30
    error_message = "Log key must be symmetric, rotating, and keep lockout safety."
  }
  assert {
    condition     = alltrue([for s in jsondecode(aws_kms_key.this.policy).Statement : alltrue([for a in s.Action : !strcontains(a, "*")])]) && jsondecode(aws_kms_key.this.policy).Statement[0].Principal.AWS == ["arn:aws:iam::123456789012:role/terraform"] && contains(jsondecode(aws_kms_key.this.policy).Statement[0].Action, "kms:PutKeyPolicy")
    error_message = "Administrators must be exact roles with enumerated actions and retain policy update permission."
  }
  assert {
    condition = jsondecode(aws_kms_key.this.policy).Statement[1].Principal.Service == "logs.ap-northeast-2.amazonaws.com" && toset(jsondecode(aws_kms_key.this.policy).Statement[1].Condition.ArnEquals["kms:EncryptionContext:aws:logs:arn"]) == toset([
      "arn:aws:logs:ap-northeast-2:123456789012:log-group:/aws/eks/platform-prod/cluster",
      "arn:aws:logs:ap-northeast-2:123456789012:log-group:/aws/containerinsights/platform-prod/application",
      "arn:aws:logs:ap-northeast-2:123456789012:log-group:/aws/containerinsights/platform-prod/performance",
      "arn:aws:logs:ap-northeast-2:123456789012:log-group:/aws/vpc/platform-prod/flow",
      "arn:aws:logs:ap-northeast-2:123456789012:log-group:aws-waf-logs-platform-prod"
    ])
    error_message = "Regional Logs key use must match all five exact encryption contexts."
  }
  assert {
    condition     = jsondecode(aws_kms_key.this.policy).Statement[2].Condition.StringEquals["kms:ViaService"] == "logs.ap-northeast-2.amazonaws.com" && try(jsondecode(aws_kms_key.this.policy).Statement[2].Condition.ArnEquals["aws:PrincipalArn"], []) == ["arn:aws:iam::123456789012:role/platform-prod-fluent-bit-role"] && jsondecode(aws_kms_key.this.policy).Statement[2].Principal.AWS == "arn:aws:iam::123456789012:root"
    error_message = "Caller key use must be constrained to the regional Logs service."
  }
}
run "reject_provider_region_mismatch" {
  command = plan
  variables {
    aws_region = "us-east-1"
  }
  expect_failures = [var.aws_region]
}
run "administrator_can_manage_the_owned_alias" {
  command = plan
  assert {
    condition     = alltrue([for action in ["kms:CreateAlias", "kms:UpdateAlias", "kms:DeleteAlias"] : contains(jsondecode(aws_kms_key.this.policy).Statement[0].Action, action)])
    error_message = "Terraform key administrators need explicit key-side alias management permission."
  }
}

run "default_owner_is_terraform" {
  command = plan
  assert {
    condition     = try(aws_kms_key.this.tags.ManagedBy, "") == "Terraform"
    error_message = "All owned taggable resources must resolve ManagedBy=Terraform when caller omits it."
  }
}
run "caller_cannot_override_terraform_owner" {
  command = plan
  variables {
    tags = { PlatformInstanceId = "platform", Owner = "team", CostCenter = "test", Environment = "prod", ManagedBy = "Other" }
  }
  assert {
    condition     = try(aws_kms_key.this.tags.ManagedBy, "") == "Terraform"
    error_message = "Caller ManagedBy cannot override Terraform resource ownership."
  }
}
