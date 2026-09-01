resource "aws_grafana_workspace" "this" {
  name                     = var.name
  description              = "Managed Grafana for ${var.name} EKS observability"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = var.authentication_providers
  permission_type          = "SERVICE_MANAGED"

  data_sources = ["PROMETHEUS", "CLOUDWATCH", "XRAY"]

  notification_destinations = ["SNS"]

  role_arn = aws_iam_role.amg.arn

  configuration = jsonencode({
    plugins = {
      pluginAdminEnabled = true
    }
    unifiedAlerting = {
      enabled = true
    }
  })

  tags = merge(var.tags, { Name = var.name })
}

# --- IAM Role for AMG ---
resource "aws_iam_role" "amg" {
  name = "${var.name}-amg-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "grafana.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(var.tags, { Name = "${var.name}-amg-role" })
}

# --- AMG → AMP READ + CloudWatch + SNS ---
resource "aws_iam_role_policy" "amg_amp" {
  name = "${var.name}-amg-amp-policy"
  role = aws_iam_role.amg.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AMPQuery"
        Effect = "Allow"
        Action = [
          "aps:ListWorkspaces",
          "aps:DescribeWorkspace",
          "aps:QueryMetrics",
          "aps:GetLabels",
          "aps:GetSeries",
          "aps:GetMetricMetadata"
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchRead"
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarmsForMetric",
          "cloudwatch:DescribeAlarmHistory",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:ListMetrics",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetInsightRuleReport"
        ]
        Resource = "*"
      },
      {
        Sid      = "SNSForAlerts"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = "*"
      }
    ]
  })
}

# There is no aws_grafana_workspace_configuration resource in the AWS provider.
# The service-managed workspace discovers AMP through data_sources = ["PROMETHEUS"]
# and the IAM permissions above. Creating a named Grafana data source is an
# explicit post-provisioning API/console operation and is deliberately outside
# this Terraform module.
