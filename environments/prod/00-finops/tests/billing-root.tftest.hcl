mock_provider "aws" {
  alias = "billing"
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_region" { defaults = { name = "us-east-1" } }
  mock_data "aws_organizations_organization" { defaults = {
    id                = "o-fixture1234"
    master_account_id = "123456789012"
    accounts          = [{ id = "210987654321", arn = "arn:aws:organizations::123456789012:account/o-fixture1234/210987654321", email = "fixture@example.invalid", name = "fixture", status = "ACTIVE" }]
  } }
}
variables {
  aws_region           = "ap-northeast-2"
  project_name         = "platform-fixture"
  platform_instance_id = "platform-fixture"
  owner                = "platform-team"
  cost_center          = "test"
  billing_account_id   = "123456789012"
  workload_account_id  = "210987654321"
  finops               = { monthly_budget_usd = 300, anomaly_threshold_usd = 20, notification_topic_arn = "arn:aws:sns:us-east-1:123456789012:billing" }
}
run "rejects_ambiguous_billing_credentials" {
  command = plan
  variables { billing_access = { profile = "billing-admin", role_arn = "arn:aws:iam::123456789012:role/billing-operator" } }
  expect_failures = [var.billing_access]
}
run "separates_workload_region_and_account_from_billing" {
  command = plan
  assert {
    condition     = output.finops.billingApiRegion == "us-east-1" && output.finops.workloadRegion == "ap-northeast-2" && output.finops.billingAccountId == "123456789012" && output.finops.workloadAccountId == "210987654321"
    error_message = "Management billing and workload identities must never collapse into one ambient account/Region."
  }
  assert {
    condition     = output.finops.requiredTags.PlatformInstanceId == "platform-fixture" && output.finops.requiredTags.ManagedBy == "Terraform" && output.finops.notificationOwnership == "EXTERNAL_SHARED"
    error_message = "Cost ownership tags must propagate without claiming external billing SNS ownership."
  }
}
run "rejects_blank_owner" {
  command = plan
  variables { owner = "" }
  expect_failures = [var.owner]
}
