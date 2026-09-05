data "aws_caller_identity" "current" {}

locals {
  subscription_enabled = var.enabled && var.enable_sns_delivery
  topic_arn            = var.enabled ? aws_sns_topic.course_alerts[0].arn : ""
  namespace            = "app-${var.environment}"
  # Canonical identity spans the Rollout's stable/canary Kubernetes Services.
  selector = "reporter=\"destination\",destination_canonical_service=\"mini-commerce\",destination_workload_namespace=\"${local.namespace}\",environment=\"${var.environment}\""
  windows  = { short = var.slo.short_window, long = var.slo.long_window }
  traffic  = { for key, window in local.windows : key => "sum(rate(istio_requests_total{${local.selector}}[${window}]))" }
  burn     = { for key, window in local.windows : key => "(sum(rate(istio_requests_total{${local.selector},response_code=~\"5..\"}[${window}])) / ${local.traffic[key]}) / (1 - ${var.slo.success_target})" }
  labels = {
    service     = "mini-commerce"
    environment = var.environment
    severity    = var.slo.paging_severity
    runbook     = var.runbook_url
  }
  business_alerts = {
    MiniCommerceOrderFailures      = "sum(rate(mini_commerce_order_failures_total{namespace=\"${local.namespace}\",environment=\"${var.environment}\"}[5m])) > 0"
    MiniCommerceInventoryConflicts = "sum(rate(mini_commerce_inventory_reservation_conflicts_total{namespace=\"${local.namespace}\",environment=\"${var.environment}\"}[5m])) > 0"
    MiniCommerceDBErrors           = "sum(rate(mini_commerce_db_pool_errors_total{namespace=\"${local.namespace}\",environment=\"${var.environment}\"}[5m])) > 0 or sum(rate(mini_commerce_db_operation_failures_total{namespace=\"${local.namespace}\",environment=\"${var.environment}\"}[5m])) > 0"
    MiniCommerceDBPoolPressure     = "sum(mini_commerce_db_pool_waiting_requests{namespace=\"${local.namespace}\",environment=\"${var.environment}\"}) > 0 and sum(mini_commerce_db_pool_connections{namespace=\"${local.namespace}\",environment=\"${var.environment}\",state=\"idle\"}) == 0"
  }

  rule_groups = {
    groups = [
      {
        name = "course-release-slo"
        rules = concat([for key, window in local.windows : {
          record = "mini_commerce:success_burn:${key}"
          expr   = local.burn[key]
          labels = { service = "mini-commerce", environment = var.environment }
          }], [
          {
            alert       = "MiniCommerceSuccessBurn"
            expr        = "(${local.burn.short} > ${var.slo.short_burn_threshold}) and (${local.burn.long} > ${var.slo.long_burn_threshold}) and (${local.traffic.short} >= ${var.slo.traffic_floor_rps}) and (${local.traffic.long} >= ${var.slo.traffic_floor_rps})"
            for         = "1m"
            labels      = local.labels
            annotations = { summary = "Mini Commerce success error budget burns in both windows", owner = var.alert_owner, query = local.burn.short }
          },
          {
            alert       = "MiniCommerceLatency"
            expr        = "histogram_quantile(0.95, sum by (le) (rate(istio_request_duration_milliseconds_bucket{${local.selector}}[${var.slo.short_window}]))) > ${var.slo.latency_ms_target} and (${local.traffic.short} >= ${var.slo.traffic_floor_rps})"
            for         = "1m"
            labels      = local.labels
            annotations = { summary = "Mini Commerce p95 latency exceeds target", owner = var.alert_owner }
          }
          ], [for name, expr in local.business_alerts : {
            alert       = name
            expr        = expr
            for         = "1m"
            labels      = local.labels
            annotations = { summary = name, owner = var.alert_owner, query = expr }
        }])
      }
    ]
  }

  alertmanager = {
    route = {
      receiver        = var.slo.escalation_route
      group_by        = ["alertname"]
      group_wait      = "10s"
      group_interval  = "1m"
      repeat_interval = "4h"
    }
    receivers = [
      {
        name = var.slo.escalation_route
        sns_configs = [
          {
            topic_arn = local.topic_arn
            # Bounded label names and printf %q preserve JSON escaping; no user labels/annotations.
            message = <<-EOT
              {"status":{{ printf "%q" .Status }},"alerts":[{{ range $i, $a := .Alerts }}{{ if $i }},{{ end }}{"status":{{ printf "%q" .Status }},"fingerprint":{{ printf "%q" .Fingerprint }},"startsAt":{{ printf "%q" (.StartsAt.UTC.Format "2006-01-02T15:04:05.999999999Z") }},"endsAt":{{ printf "%q" (.EndsAt.UTC.Format "2006-01-02T15:04:05.999999999Z") }},"labels":{"alertname":{{ printf "%q" .Labels.alertname }},"service":{{ printf "%q" .Labels.service }},"environment":{{ printf "%q" .Labels.environment }},"severity":{{ printf "%q" .Labels.severity }},"runbook":{{ printf "%q" .Labels.runbook }}}}{{ end }}]}
            EOT
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
  data         = yamlencode(local.rule_groups)
  lifecycle {
    precondition {
      condition     = var.workspace_arn == "arn:aws:aps:${var.aws_region}:${data.aws_caller_identity.current.account_id}:workspace/${var.workspace_id}"
      error_message = "AMP workspace must match workspace ID, caller account and notification Region."
    }
  }
}

resource "aws_prometheus_alert_manager_definition" "course" {
  count = var.enabled ? 1 : 0

  workspace_id = var.workspace_id
  definition   = yamlencode({ alertmanager_config = yamlencode(local.alertmanager) })

  depends_on = [aws_sns_topic_policy.amp_publish]
}
