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

run "budget_and_anomaly_use_the_same_platform_scope_and_external_sns" {
  command = plan

  override_resource {
    target          = aws_ce_anomaly_monitor.platform
    override_during = plan
    values          = { arn = "arn:aws:ce::123456789012:anomalymonitor/12345678-1234-1234-1234-123456789012" }
  }

  assert {
    condition = (
      aws_budgets_budget.platform.budget_type == "COST" &&
      aws_budgets_budget.platform.limit_amount == "500" &&
      aws_budgets_budget.platform.limit_unit == "USD" &&
      aws_budgets_budget.platform.time_unit == "MONTHLY" &&
      toset([for n in aws_budgets_budget.platform.notification : n.threshold]) == toset([50, 80, 100]) &&
      alltrue([for n in aws_budgets_budget.platform.notification :
        n.notification_type == "ACTUAL" && n.threshold_type == "PERCENTAGE" &&
        n.comparison_operator == "GREATER_THAN" &&
        toset(n.subscriber_sns_topic_arns) == toset(["arn:aws:sns:us-east-1:123456789012:billing-alerts"]) &&
        length(coalesce(n.subscriber_email_addresses, toset([]))) == 0
      ])
    )
    error_message = "All three actual monthly cost thresholds must target the external billing SNS topic."
  }
  assert {
    condition = (
      toset(one([for f in aws_budgets_budget.platform.cost_filter : f if f.name == "TagKeyValue"]).values) == toset(["user:PlatformInstanceId$commerce-123"]) &&
      toset(one([for f in aws_budgets_budget.platform.cost_filter : f if f.name == "LinkedAccount"]).values) == toset(["210987654321"]) &&
      aws_ce_anomaly_monitor.platform.monitor_type == "CUSTOM" &&
      jsondecode(aws_ce_anomaly_monitor.platform.monitor_specification).Tags.Key == "PlatformInstanceId" &&
      jsondecode(aws_ce_anomaly_monitor.platform.monitor_specification).Tags.Values == ["commerce-123"]
    )
    error_message = "Budget must bind workload account plus platform tag; anomaly monitor must retain the supported organization-wide tag-only scope."
  }
  assert {
    condition = (
      aws_ce_anomaly_subscription.platform.frequency == "IMMEDIATE" &&
      toset(aws_ce_anomaly_subscription.platform.monitor_arn_list) == toset(["arn:aws:ce::123456789012:anomalymonitor/12345678-1234-1234-1234-123456789012"]) &&
      alltrue([for s in aws_ce_anomaly_subscription.platform.subscriber : s.type == "SNS" && s.address == "arn:aws:sns:us-east-1:123456789012:billing-alerts"]) &&
      one(one(aws_ce_anomaly_subscription.platform.threshold_expression).dimension).key == "ANOMALY_TOTAL_IMPACT_ABSOLUTE" &&
      toset(one(one(aws_ce_anomaly_subscription.platform.threshold_expression).dimension).values) == toset(["25"])
    )
    error_message = "Immediate SNS anomaly delivery must use a positive absolute USD threshold and the actual monitor."
  }
  assert {
    condition = (
      output.finops_contract.workloadRegion == "ap-northeast-2" &&
      output.finops_contract.billingApiRegion == "us-east-1" &&
      output.finops_contract.notificationOwnership == "EXTERNAL_SHARED" &&
      aws_budgets_budget.platform.tags["Owner"] == "platform-sre" &&
      aws_ce_anomaly_monitor.platform.tags["PlatformInstanceId"] == "commerce-123" &&
      aws_ce_anomaly_subscription.platform.tags["Environment"] == "prod"
    )
    error_message = "Workload Region must remain distinct from billing endpoints and all owned resources must be tagged."
  }
}

run "rejects_cross_account_billing_topic" {
  command = plan
  variables { finops = merge(var.finops, { notification_topic_arn = "arn:aws:sns:us-east-1:999999999999:billing-alerts" }) }
  expect_failures = [aws_budgets_budget.platform]
}

run "rejects_workload_provider_used_for_billing" {
  command = plan
  override_data {
    target = data.aws_region.current
    values = { name = "ap-northeast-2" }
  }
  expect_failures = [aws_budgets_budget.platform]
}
