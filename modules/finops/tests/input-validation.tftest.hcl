mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_region" {
    defaults = { name = "us-east-1" }
  }
  mock_data "aws_organizations_organization" {
    defaults = { master_account_id = "123456789012", accounts = [{ id = "210987654321", arn = "arn:aws:organizations::123456789012:account/o-example/210987654321", name = "workload", email = "workload@example.invalid", status = "ACTIVE" }] }
  }
}

variables {
  billing_account_id  = "123456789012"
  workload_account_id = "210987654321"
  name                = "commerce-prod"
  workload_region     = "ap-northeast-2"
  finops = {
    monthly_budget_usd          = 500
    alert_threshold_percentages = [50, 80, 100]
    anomaly_threshold_usd       = 25
    notification_topic_arn      = "arn:aws:sns:us-east-1:123456789012:billing-alerts"
    required_tags = {
      PlatformInstanceId = "commerce-123"
      Owner              = "platform-sre"
      CostCenter         = "cc-100"
      Environment        = "prod"
    }
  }
}

run "rejects_zero_budget" {
  command = plan
  variables { finops = merge(var.finops, { monthly_budget_usd = 0 }) }
  expect_failures = [var.finops]
}

run "rejects_zero_anomaly_threshold" {
  command = plan
  variables { finops = merge(var.finops, { anomaly_threshold_usd = 0 }) }
  expect_failures = [var.finops]
}

run "rejects_missing_final_budget_threshold" {
  command = plan
  variables { finops = merge(var.finops, { alert_threshold_percentages = [50, 80] }) }
  expect_failures = [var.finops]
}

run "rejects_empty_owner" {
  command = plan
  variables { finops = merge(var.finops, { required_tags = merge(var.finops.required_tags, { Owner = " " }) }) }
  expect_failures = [var.finops]
}

run "rejects_missing_cost_scope" {
  command = plan
  variables { finops = merge(var.finops, { required_tags = { Owner = "sre" } }) }
  expect_failures = [var.finops]
}

run "rejects_missing_external_topic" {
  command = plan
  variables { finops = merge(var.finops, { notification_topic_arn = "" }) }
  expect_failures = [var.finops]
}
