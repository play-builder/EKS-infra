data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_organizations_organization" "billing" {}

locals {
  platform_id = lookup(var.finops.required_tags, "PlatformInstanceId", "")
  tags        = merge(var.finops.required_tags, { ManagedBy = "Terraform" })
}

resource "aws_budgets_budget" "platform" {
  name         = "${var.name}-monthly"
  account_id   = data.aws_caller_identity.current.account_id
  budget_type  = "COST"
  limit_amount = tostring(var.finops.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"
  tags         = local.tags

  lifecycle {
    precondition {
      condition     = data.aws_region.current.name == "us-east-1"
      error_message = "Cost management resources require a us-east-1 billing provider, independently of the workload Region."
    }
    precondition {
      condition     = try(split(":", var.finops.notification_topic_arn)[4], "") == data.aws_caller_identity.current.account_id
      error_message = "The external billing SNS topic must belong to the account that owns the budget and anomaly monitor."
    }
  }

  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:PlatformInstanceId$%s", local.platform_id)]
  }
  cost_filter {
    name   = "LinkedAccount"
    values = [var.workload_account_id]
  }

  dynamic "notification" {
    for_each = var.finops.alert_threshold_percentages
    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value
      threshold_type            = "PERCENTAGE"
      notification_type         = "ACTUAL"
      subscriber_sns_topic_arns = [var.finops.notification_topic_arn]
    }
  }
}

resource "aws_ce_anomaly_monitor" "platform" {
  name         = "${var.name}-cost-anomalies"
  monitor_type = "CUSTOM"
  monitor_specification = jsonencode({
    Tags = {
      Key          = "PlatformInstanceId"
      Values       = [local.platform_id]
      MatchOptions = ["EQUALS"]
    }
  })
  tags = local.tags
  lifecycle {
    precondition {
      condition = (
        data.aws_caller_identity.current.account_id == var.billing_account_id &&
        data.aws_organizations_organization.billing.master_account_id == var.billing_account_id &&
        contains([for account in data.aws_organizations_organization.billing.accounts : account.id], var.workload_account_id)
      )
      error_message = "CUSTOM tag monitors require the expected Organizations management-account billing provider and a workload account in that organization."
    }
  }
}

resource "aws_ce_anomaly_subscription" "platform" {
  name             = "${var.name}-cost-alerts"
  account_id       = data.aws_caller_identity.current.account_id
  frequency        = "IMMEDIATE"
  monitor_arn_list = [aws_ce_anomaly_monitor.platform.arn]
  tags             = local.tags

  subscriber {
    type    = "SNS"
    address = var.finops.notification_topic_arn
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.finops.anomaly_threshold_usd)]
    }
  }
}
