mock_provider "aws" {}
override_data {
  target = data.aws_caller_identity.current
  values = { account_id = "123456789012" }
}
run "reject_wildcard_enterprise_scope" {
  command = plan
  variables {
    enterprise_resource_arns = { rds = ["arn:aws:rds:ap-northeast-2:123456789012:db:*"], secrets = [], kms = [], waf = [], sns = [] }
  }
  expect_failures = [var.enterprise_resource_arns]
}
run "reject_wildcard_billing_observer" {
  command = plan
  variables { billing_monitor_role_arn = "arn:aws:iam::111122223333:role/*" }
  expect_failures = [var.billing_monitor_role_arn]
}
run "optional_billing_observer_is_exact" {
  command = plan
  variables { billing_monitor_role_arn = "arn:aws:iam::111122223333:role/readonly-billing-observer" }
  assert {
    condition     = one([for s in jsondecode(aws_iam_policy.enterprise.policy).Statement : s if s.Sid == "ExactReadOnlyBillingObserver"]).Resource == ["arn:aws:iam::111122223333:role/readonly-billing-observer"] && output.billing_observer_handoff.managementProvisioning == false
    error_message = "Only one externally managed read-only observer role is assumable."
  }
}
run "exact_lifecycle_grants_do_not_read_values_or_bill_management" {
  command = plan
  variables {
    enterprise_resource_arns = {
      rds     = ["arn:aws:rds:ap-northeast-2:123456789012:db:fixture"]
      secrets = ["arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:prod/mini-commerce/database-abcdef"]
      kms     = ["arn:aws:kms:ap-northeast-2:123456789012:key/12345678-1234-1234-1234-123456789012"]
      waf     = []
      sns     = ["arn:aws:sns:ap-northeast-2:123456789012:prod-amp-alerts"]
    }
    enterprise_secret_names = ["prod/mini-commerce/database"]
  }
  assert {
    condition     = alltrue([for s in jsondecode(aws_iam_policy.enterprise.policy).Statement : alltrue([for a in s.Action : !contains(["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue", "secretsmanager:UpdateSecret", "kms:Decrypt", "sns:Publish", "rds:DeleteDBSnapshot"], a) && !startswith(a, "organizations:") && !startswith(a, "budgets:") && !startswith(a, "ce:")])])
    error_message = "Provisioner cannot read/write existing credential values, decrypt logs, deliver alerts, erase retained snapshots or manage billing."
  }
  assert {
    condition     = one([for s in jsondecode(aws_iam_policy.enterprise.policy).Statement : s if s.Sid == "ExactDatabaseLifecycle"]).Resource == ["arn:aws:rds:ap-northeast-2:123456789012:db:fixture"]
    error_message = "The database lifecycle grant must preserve the exact configured resource ARN."
  }
  assert {
    condition     = alltrue([for a in local.workload_state_objects : !strcontains(a, "00-finops") && !strcontains(a, "platform-backup") && !strcontains(a, "*")])
    error_message = "Management billing and protected backup state do not belong to workload OIDC."
  }
}
run "reject_other_account_scope" {
  command = plan
  variables {
    enterprise_resource_arns = { rds = [], secrets = [], kms = [], waf = [], sns = ["arn:aws:sns:ap-northeast-2:111122223333:billing"] }
  }
  expect_failures = [aws_iam_policy.enterprise]
}
variables {
  state_bucket_arns = ["arn:aws:s3:::course-state"]
  aws_region        = "ap-northeast-2"
  tags              = { PlatformInstanceId = "fixture", Owner = "platform", CostCenter = "engineering" }
}
run "state_and_runtime_secret_boundaries" {
  command = plan
  assert {
    condition     = !contains(flatten([for s in jsondecode(aws_iam_policy.infra.policy).Statement : s.Action]), "secretsmanager:*")
    error_message = "Infrastructure provisioning must not read or write runtime secret values."
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_policy.infra.policy).Statement : s if contains(s.Action, "s3:DeleteObject") && alltrue([for r in s.Resource : endswith(r, ".tflock")])]) == 1
    error_message = "Native S3 locking needs DeleteObject on exact lock objects, never state objects."
  }
  assert {
    condition     = !anytrue([for s in jsondecode(aws_iam_policy.infra.policy).Statement : anytrue([for a in s.Action : startswith(a, "organizations:") || startswith(a, "budgets:") || startswith(a, "ce:")])])
    error_message = "Billing management roles must remain outside workload OIDC."
  }
}
