mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { name = "ap-northeast-2" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
}
variables {
  name           = "platform-prod"
  environment    = "prod"
  account_id     = "123456789012"
  aws_region     = "ap-northeast-2"
  kms_key_arn    = "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-2222-3333-4444-555555555555"
  retention_days = 90
  tags           = { PlatformInstanceId = "platform", Owner = "team", CostCenter = "test", Environment = "prod" }
}
run "reject_prod_short_retention" {
  command = plan
  variables { retention_days = 30 }
  expect_failures = [var.retention_days]
}
run "reject_unsupported_retention" {
  command = plan
  variables { retention_days = 91 }
  expect_failures = [var.retention_days]
}

run "reject_cross_region_key" {
  command = plan
  variables { kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555" }
  expect_failures = [var.kms_key_arn]
}
run "reject_unbounded_rate" {
  command = plan
  variables { rate_limit = 100001 }
  expect_failures = [var.rate_limit]
}
run "reject_fractional_rate" {
  command = plan
  variables { rate_limit = 99.5 }
  expect_failures = [var.rate_limit]
}
run "render_regional_protection" {
  command = plan
  assert {
    condition     = aws_wafv2_web_acl.this.scope == "REGIONAL" && length(aws_wafv2_web_acl.this.default_action[0].allow) == 1 && length(aws_wafv2_web_acl.this.rule) == 4
    error_message = "WAF requires regional scope, default allow and three baselines plus a rate rule."
  }
  assert {
    condition     = !aws_wafv2_web_acl.this.visibility_config[0].sampled_requests_enabled && alltrue([for r in aws_wafv2_web_acl.this.rule : !r.visibility_config[0].sampled_requests_enabled && r.visibility_config[0].cloudwatch_metrics_enabled])
    error_message = "Sampling must remain disabled across ACL and rules to prevent redaction bypass."
  }
  assert {
    condition     = toset([for r in aws_wafv2_web_acl.this.rule : r.name if length(r.statement[0].managed_rule_group_statement) > 0]) == toset(["AWSManagedRulesCommonRuleSet", "AWSManagedRulesKnownBadInputsRuleSet", "AWSManagedRulesAmazonIpReputationList"]) && alltrue([for r in aws_wafv2_web_acl.this.rule : r.statement[0].rate_based_statement[0].limit == 2000 && r.statement[0].rate_based_statement[0].aggregate_key_type == "IP" if r.name == "PerIPRateLimit"])
    error_message = "Mandatory AWS baselines and bounded source-IP rate limit must render."
  }
  assert {
    condition     = aws_cloudwatch_log_group.waf.name == "aws-waf-logs-platform-prod" && aws_cloudwatch_log_group.waf.retention_in_days == 90 && aws_cloudwatch_log_group.waf.kms_key_id == var.kms_key_arn && aws_wafv2_web_acl_logging_configuration.this.log_destination_configs == toset(["arn:aws:logs:ap-northeast-2:123456789012:log-group:aws-waf-logs-platform-prod"])
    error_message = "WAF logging requires the exact prefixed encrypted same-account group with no stream suffix."
  }
  assert {
    condition     = toset(flatten([for f in aws_wafv2_web_acl_logging_configuration.this.redacted_fields : [for h in f.single_header : h.name]])) == toset(["authorization", "cookie", "x-api-key"]) && length([for f in aws_wafv2_web_acl_logging_configuration.this.redacted_fields : f if length(f.query_string) > 0]) == 1
    error_message = "Credential headers and query string must all be redacted."
  }
  assert {
    condition     = jsondecode(aws_cloudwatch_log_resource_policy.waf.policy_document).Statement[0].Principal.Service == "delivery.logs.amazonaws.com" && jsondecode(aws_cloudwatch_log_resource_policy.waf.policy_document).Statement[0].Resource == "arn:aws:logs:ap-northeast-2:123456789012:log-group:aws-waf-logs-platform-prod:log-stream:*" && toset(jsondecode(aws_cloudwatch_log_resource_policy.waf.policy_document).Statement[0].Action) == toset(["logs:CreateLogStream", "logs:PutLogEvents"]) && jsondecode(aws_cloudwatch_log_resource_policy.waf.policy_document).Statement[0].Condition.StringEquals["aws:SourceAccount"] == "123456789012" && jsondecode(aws_cloudwatch_log_resource_policy.waf.policy_document).Statement[0].Condition.ArnLike["aws:SourceArn"] == "arn:aws:logs:ap-northeast-2:123456789012:*"
    error_message = "Log delivery resource policy must scope principal, actions, group streams and source identity."
  }
}
run "reject_provider_region_mismatch" {
  command = plan
  variables {
    aws_region  = "us-east-1"
    kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  }
  expect_failures = [var.aws_region]
}

run "default_owner_is_terraform" {
  command = plan
  assert {
    condition     = try(aws_wafv2_web_acl.this.tags.ManagedBy, "") == "Terraform" && try(aws_cloudwatch_log_group.waf.tags.ManagedBy, "") == "Terraform"
    error_message = "All owned taggable resources must resolve ManagedBy=Terraform when caller omits it."
  }
}
run "caller_cannot_override_terraform_owner" {
  command = plan
  variables {
    tags = { PlatformInstanceId = "platform", Owner = "team", CostCenter = "test", Environment = "prod", ManagedBy = "Other" }
  }
  assert {
    condition     = try(aws_wafv2_web_acl.this.tags.ManagedBy, "") == "Terraform" && try(aws_cloudwatch_log_group.waf.tags.ManagedBy, "") == "Terraform"
    error_message = "Caller ManagedBy cannot override Terraform resource ownership."
  }
}
