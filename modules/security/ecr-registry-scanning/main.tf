data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_ecr_registry_scanning_configuration" "this" {
  count     = var.configuration.ownership_mode == "terraform" ? 1 : 0
  scan_type = "ENHANCED"
  rule {
    scan_frequency = "CONTINUOUS_SCAN"
    dynamic "repository_filter" {
      for_each = var.configuration.repository_filters
      content {
        filter      = repository_filter.value
        filter_type = "WILDCARD"
      }
    }
  }
  dynamic "rule" {
    for_each = length(var.configuration.scan_on_push_repository_filters) > 0 ? [1] : []
    content {
      scan_frequency = "SCAN_ON_PUSH"
      dynamic "repository_filter" {
        for_each = var.configuration.scan_on_push_repository_filters
        content {
          filter      = repository_filter.value
          filter_type = "WILDCARD"
        }
      }
    }
  }
  lifecycle {
    prevent_destroy = true
    precondition {
      condition = try(
        var.ownership_handoff.account_id == data.aws_caller_identity.current.account_id &&
        var.ownership_handoff.aws_region == data.aws_region.current.name, false
      )
      error_message = "Scanning handoff must match the authenticated account and configured region."
    }
  }
}
