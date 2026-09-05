mock_provider "aws" {
  mock_data "aws_caller_identity" {
    override_during = plan
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_resource "aws_sns_topic" {
    override_during = plan
    defaults = {
      arn = "arn:aws:sns:ap-northeast-2:123456789012:course-dev-amp-alerts"
    }
  }
}

run "disabled_without_ch16_flag" {
  command = plan

  variables {
    enabled             = false
    workspace_id        = "ws-12345678-abcd-1234-abcd-123456789012"
    workspace_arn       = "arn:aws:aps:ap-northeast-2:123456789012:workspace/ws-12345678-abcd-1234-abcd-123456789012"
    aws_region          = "ap-northeast-2"
    enable_sns_delivery = false
    sns_email_endpoint  = null
  }

  assert {
    condition = (
      length(aws_prometheus_rule_group_namespace.course) == 0 &&
      length(aws_prometheus_alert_manager_definition.course) == 0 &&
      length(aws_sns_topic.course_alerts) == 0
    )
    error_message = "AMP alerting resources must be absent until Ch16."
  }
}

run "alerting_does_not_require_an_unconfirmed_email_subscription" {
  command = plan

  variables {
    enabled             = true
    workspace_id        = "ws-12345678-abcd-1234-abcd-123456789012"
    workspace_arn       = "arn:aws:aps:ap-northeast-2:123456789012:workspace/ws-12345678-abcd-1234-abcd-123456789012"
    aws_region          = "ap-northeast-2"
    enable_sns_delivery = false
    sns_email_endpoint  = null
  }

  assert {
    condition = (
      length(aws_prometheus_rule_group_namespace.course) == 1 &&
      length(aws_prometheus_alert_manager_definition.course) == 1 &&
      length(aws_sns_topic.course_alerts) == 1 &&
      length(aws_sns_topic_subscription.email) == 0
    )
    error_message = "Ch16 alerting must exist without creating an unrequested email subscription."
  }
}

run "sns_policy_scopes_amp_publish_to_workspace" {
  command = plan

  variables {
    enabled             = true
    workspace_id        = "ws-12345678-abcd-1234-abcd-123456789012"
    workspace_arn       = "arn:aws:aps:ap-northeast-2:123456789012:workspace/ws-12345678-abcd-1234-abcd-123456789012"
    aws_region          = "ap-northeast-2"
    enable_sns_delivery = true
    sns_email_endpoint  = "oncall@example.com"
  }

  assert {
    condition = (
      length(aws_sns_topic.course_alerts) == 1 &&
      strcontains(aws_sns_topic_policy.amp_publish[0].policy, "aps.amazonaws.com") &&
      strcontains(aws_sns_topic_policy.amp_publish[0].policy, "AWS:SourceAccount") &&
      strcontains(aws_sns_topic_policy.amp_publish[0].policy, "AWS:SourceArn")
    )
    error_message = "SNS delivery must be created with an AMP-only SourceAccount/SourceArn policy."
  }

  assert {
    condition     = try(yamldecode(yamldecode(aws_prometheus_alert_manager_definition.course[0].definition).alertmanager_config).receivers[0].sns_configs[0].sigv4.region == "ap-northeast-2", false)
    error_message = "Alertmanager SNS receiver must sign in the selected AWS Region."
  }
}
