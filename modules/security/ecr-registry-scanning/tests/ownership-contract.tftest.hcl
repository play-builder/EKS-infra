mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_region" { defaults = { name = "ap-northeast-2" } }
}
variables {
  required_repositories = ["mini-commerce", "platform/istio-proxy"]
  configuration = {
    ownership_mode                  = "terraform"
    scan_type                       = "ENHANCED"
    scan_frequency                  = "CONTINUOUS_SCAN"
    repository_filters              = ["mini-commerce", "platform/istio-proxy", "other-team/*"]
    scan_on_push_repository_filters = ["legacy/*"]
  }
  ownership_handoff = { account_id = "123456789012", aws_region = "ap-northeast-2", approval_reference = "CHG-12345678" }
}
run "preserves_other_teams_filters" {
  command = plan
  assert {
    condition     = aws_ecr_registry_scanning_configuration.this[0].scan_type == "ENHANCED" && length(aws_ecr_registry_scanning_configuration.this[0].rule) == 2 && contains(flatten([for rule in aws_ecr_registry_scanning_configuration.this[0].rule : [for f in rule.repository_filter : f.filter]]), "other-team/*")
    error_message = "Reviewed full-registry rules must retain other teams' continuous and on-push filters."
  }
}
run "rejects_missing_handoff" {
  command = plan
  variables { ownership_handoff = null }
  expect_failures = [var.ownership_handoff]
}
run "rejects_wrong_account" {
  command = plan
  variables { ownership_handoff = { account_id = "999999999999", aws_region = "ap-northeast-2", approval_reference = "CHG-12345678" } }
  expect_failures = [aws_ecr_registry_scanning_configuration.this]
}
run "rejects_wrong_region" {
  command = plan
  variables { ownership_handoff = { account_id = "123456789012", aws_region = "us-east-1", approval_reference = "CHG-12345678" } }
  expect_failures = [aws_ecr_registry_scanning_configuration.this]
}
run "rejects_missing_repository" {
  command = plan
  variables { configuration = { ownership_mode = "terraform", scan_type = "ENHANCED", scan_frequency = "CONTINUOUS_SCAN", repository_filters = ["mini-commerce"] } }
  expect_failures = [var.configuration]
}
run "rejects_basic" {
  command = plan
  variables { configuration = { ownership_mode = "terraform", scan_type = "BASIC", scan_frequency = "CONTINUOUS_SCAN", repository_filters = ["mini-commerce", "platform/istio-proxy"] } }
  expect_failures = [var.configuration]
}
run "external_owner_creates_nothing" {
  command = plan
  variables {
    configuration     = { ownership_mode = "external", scan_type = "ENHANCED", scan_frequency = "CONTINUOUS_SCAN", repository_filters = [] }
    ownership_handoff = null
  }
  assert {
    condition     = length(aws_ecr_registry_scanning_configuration.this) == 0 && !output.contract.liveVerified
    error_message = "External ownership must never be overwritten or reported as live-verified."
  }
}
