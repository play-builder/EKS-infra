data "aws_caller_identity" "current" {}

locals {
  subscription_enabled = var.enabled && var.enable_sns_delivery
  topic_arn            = var.enabled ? aws_sns_topic.course_alerts[0].arn : ""

  rule_groups = {
    groups = [
      {
        name = "course-release-slo"
        rules = [
          {
            record = "course:http_success_ratio:5m"
            expr   = "sum(rate(http_requests_total{status!~\"5..\"}[5m])) / clamp_min(sum(rate(http_requests_total[5m])), 1)"
          },
          {
            alert = "CourseDeadman"
            expr  = "vector(1)"
            for   = "1m"
            labels = {
              severity = "info"
            }
          }
        ]
      }
    ]
  }

  alertmanager = {
    route = {
      receiver        = "course-sns"
      group_by        = ["alertname"]
      group_wait      = "10s"
      group_interval  = "1m"
      repeat_interval = "4h"
    }
    receivers = [
      {
        name = "course-sns"
        sns_configs = [
          {
            topic_arn = local.topic_arn
            sigv4 = {
              region = var.aws_region
            }
            send_resolved = true
          }
        ]
      }
    ]
  }
}

resource "aws_sns_topic" "course_alerts" {
  count = var.enabled ? 1 : 0

  name = "${var.name}-amp-alerts"
  tags = var.tags
}

resource "aws_sns_topic_policy" "amp_publish" {
  count = var.enabled ? 1 : 0

  arn = aws_sns_topic.course_alerts[0].arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAmpWorkspacePublish"
        Effect    = "Allow"
        Principal = { Service = "aps.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.course_alerts[0].arn
        Condition = {
          StringEquals = {
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnEquals = {
            "AWS:SourceArn" = var.workspace_arn
          }
        }
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "email" {
  count = local.subscription_enabled ? 1 : 0

  topic_arn = aws_sns_topic.course_alerts[0].arn
  protocol  = "email"
  endpoint  = var.sns_email_endpoint
}

resource "aws_prometheus_rule_group_namespace" "course" {
  count = var.enabled ? 1 : 0

  name         = "course-release-slo"
  workspace_id = var.workspace_id
  data         = base64encode(yamlencode(local.rule_groups))
}

resource "aws_prometheus_alert_manager_definition" "course" {
  count = var.enabled ? 1 : 0

  workspace_id = var.workspace_id
  definition   = base64encode(yamlencode(local.alertmanager))

  depends_on = [aws_sns_topic_policy.amp_publish]
}
