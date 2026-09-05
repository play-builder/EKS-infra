mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_region" { defaults = { name = "us-east-1" } }
  mock_data "aws_organizations_organization" {
    defaults = { master_account_id = "123456789012", accounts = [{ id = "210987654321", arn = "arn:aws:organizations::123456789012:account/o-example/210987654321", name = "workload", email = "workload@example.invalid", status = "ACTIVE" }] }
  }
}
variables {
  name                = "commerce-prod"
  workload_region     = "ap-northeast-2"
  billing_account_id  = "123456789012"
  workload_account_id = "210987654321"
  finops = {
    monthly_budget_usd          = 500
    alert_threshold_percentages = [50, 80, 100]
    anomaly_threshold_usd       = 25
    notification_topic_arn      = "arn:aws:sns:us-east-1:123456789012:billing-alerts"
    required_tags               = { PlatformInstanceId = "commerce-123", Owner = "platform-sre", CostCenter = "cc-100", Environment = "prod", ManagedBy = "incorrect-owner" }
  }
}
run "rejects_member_account_credentials_for_tag_monitor" {
  command = plan
  override_data {
    target = data.aws_organizations_organization.billing
    values = { master_account_id = "999999999999", accounts = [] }
  }
  expect_failures = [aws_ce_anomaly_monitor.platform]
}
run "rejects_unexpected_billing_provider_identity" {
  command = plan
  variables { billing_account_id = "999999999999" }
  expect_failures = [aws_ce_anomaly_monitor.platform]
}
run "rejects_workload_outside_billing_organization" {
  command = plan
  variables { workload_account_id = "888888888888" }
  expect_failures = [aws_ce_anomaly_monitor.platform]
}
run "keeps_distinct_cost_scopes_and_authoritative_owner_tag" {
  command = plan
  assert {
    condition = alltrue([
      aws_budgets_budget.platform.tags.ManagedBy == "Terraform",
      aws_ce_anomaly_monitor.platform.tags.ManagedBy == "Terraform",
      aws_ce_anomaly_subscription.platform.tags.ManagedBy == "Terraform",
    ])
    error_message = "Owned billing resources cannot omit or override their Terraform ownership tag."
  }
  assert {
    condition = (
      output.finops_contract.billingAccountId == "123456789012" &&
      output.finops_contract.workloadAccountId == "210987654321" &&
      output.finops_contract.budgetScope.linkedAccountId == "210987654321" &&
      output.finops_contract.anomalyScope.boundary == "BILLING_ORGANIZATION" &&
      output.finops_contract.requiredTags.ManagedBy == "Terraform" &&
      length(keys(jsondecode(aws_ce_anomaly_monitor.platform.monitor_specification))) == 1 &&
      contains(keys(jsondecode(aws_ce_anomaly_monitor.platform.monitor_specification)), "Tags")
    )
    error_message = "Metadata must distinguish actual billing/workload identities and budget/account versus anomaly/organization scope."
  }
}
