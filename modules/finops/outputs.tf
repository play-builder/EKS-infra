output "finops_contract" {
  description = "Cost-resource identities and scope; API readiness and notification delivery require separate verification."
  value = {
    schemaVersion         = "platform.finops/v1"
    billingAccountId      = data.aws_caller_identity.current.account_id
    workloadAccountId     = var.workload_account_id
    organizationId        = data.aws_organizations_organization.billing.id
    billingApiRegion      = data.aws_region.current.name
    workloadRegion        = var.workload_region
    notificationRegion    = "us-east-1"
    notificationOwnership = "EXTERNAL_SHARED"
    notificationTopicArn  = var.finops.notification_topic_arn
    budgetArn             = aws_budgets_budget.platform.arn
    budgetName            = aws_budgets_budget.platform.name
    monitorArn            = aws_ce_anomaly_monitor.platform.arn
    subscriptionArn       = aws_ce_anomaly_subscription.platform.arn
    monthlyBudgetUsd      = var.finops.monthly_budget_usd
    thresholdPercentages  = var.finops.alert_threshold_percentages
    anomalyThresholdUsd   = var.finops.anomaly_threshold_usd
    requiredTags          = local.tags
    budgetScope = {
      linkedAccountId = var.workload_account_id
      tagKey          = "PlatformInstanceId"
      tagValue        = local.platform_id
    }
    anomalyScope = {
      boundary = "BILLING_ORGANIZATION"
      tagKey   = "PlatformInstanceId"
      tagValue = local.platform_id
    }
  }
}
