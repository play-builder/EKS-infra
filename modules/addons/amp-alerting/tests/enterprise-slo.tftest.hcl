mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:ap-northeast-2:123456789012:test-amp-alerts" }
  }
}
variables {
  enabled       = true
  workspace_id  = "ws-12345678-abcd-1234-abcd-123456789012"
  workspace_arn = "arn:aws:aps:ap-northeast-2:123456789012:workspace/ws-12345678-abcd-1234-abcd-123456789012"
  aws_region    = "ap-northeast-2"
}
run "provider_accepts_raw_rule_yaml" {
  command = apply
  assert {
    condition     = try(length(yamldecode(aws_prometheus_rule_group_namespace.course[0].data).groups[0].rules) >= 8, false)
    error_message = "Provider input must be raw rule YAML with service and business alerts."
  }
  assert {
    condition     = try(yamldecode(yamldecode(aws_prometheus_alert_manager_definition.course[0].definition).alertmanager_config).receivers[0].sns_configs[0].send_resolved, false)
    error_message = "Nested Alertmanager YAML must route firing and resolved alerts."
  }
}

run "zero_traffic_floor_rejected" {
  command = plan
  variables {
    slo = {
      success_target                = 0.999
      latency_ms_target             = 500
      short_window                  = "5m"
      long_window                   = "1h"
      short_burn_threshold          = 14.4
      long_burn_threshold           = 14.4
      traffic_floor_rps             = 0
      paging_severity               = "critical"
      escalation_route              = "platform-sns"
      alert_resolve_timeout_minutes = 15
    }
  }
  expect_failures = [var.slo]
}

run "workspace_account_mismatch_rejected" {
  command = plan
  variables {
    workspace_arn = "arn:aws:aps:ap-northeast-2:999999999999:workspace/ws-12345678-abcd-1234-abcd-123456789012"
  }
  expect_failures = [aws_prometheus_rule_group_namespace.course]
}

run "workspace_region_mismatch_rejected" {
  command = plan
  variables {
    workspace_arn = "arn:aws:aps:us-east-1:123456789012:workspace/ws-12345678-abcd-1234-abcd-123456789012"
  }
  expect_failures = [aws_prometheus_rule_group_namespace.course]
}
