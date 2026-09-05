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
  lifecycle { prevent_destroy = true }
}
