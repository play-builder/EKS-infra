locals {
  owned_tags     = merge(var.tags, { ManagedBy = "Terraform" })
  log_group_name = "aws-waf-logs-${var.name}"
  log_group_arn  = "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:${local.log_group_name}"
  managed_rules = {
    AWSManagedRulesCommonRuleSet          = 10
    AWSManagedRulesKnownBadInputsRuleSet  = 20
    AWSManagedRulesAmazonIpReputationList = 30
  }
}
resource "aws_cloudwatch_log_group" "waf" {
  name              = local.log_group_name
  retention_in_days = var.retention_days
  kms_key_id        = var.kms_key_arn
  tags              = local.owned_tags
}
resource "aws_cloudwatch_log_resource_policy" "waf" {
  policy_name = "${var.name}-waf-log-delivery"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "WAFDeliveryToExactGroup"
      Effect    = "Allow"
      Principal = { Service = "delivery.logs.amazonaws.com" }
      Action    = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource  = "${local.log_group_arn}:log-stream:*"
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:logs:${var.aws_region}:${var.account_id}:*" }
      }
    }]
  })
}
resource "aws_wafv2_web_acl" "this" {
  name  = var.name
  scope = "REGIONAL"
  default_action {
    allow {}
  }
  dynamic "rule" {
    for_each = local.managed_rules
    content {
      name     = rule.key
      priority = rule.value
      override_action {
        none {}
      }
      statement {
        managed_rule_group_statement {
          name        = rule.key
          vendor_name = "AWS"
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name}-${rule.key}"
        sampled_requests_enabled   = false
      }
    }
  }
  rule {
    name     = "PerIPRateLimit"
    priority = 100
    action {
      block {}
    }
    statement {
      rate_based_statement {
        aggregate_key_type    = "IP"
        limit                 = var.rate_limit
        evaluation_window_sec = 300
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-rate-limit"
      sampled_requests_enabled   = false
    }
  }
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-web-acl"
    sampled_requests_enabled   = false
  }
  tags = local.owned_tags
}
resource "aws_wafv2_web_acl_logging_configuration" "this" {
  resource_arn            = aws_wafv2_web_acl.this.arn
  log_destination_configs = [local.log_group_arn]
  redacted_fields {
    single_header { name = "authorization" }
  }
  redacted_fields {
    single_header { name = "cookie" }
  }
  redacted_fields {
    single_header { name = "x-api-key" }
  }
  redacted_fields {
    query_string {}
  }
  depends_on = [aws_cloudwatch_log_group.waf, aws_cloudwatch_log_resource_policy.waf]
}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
