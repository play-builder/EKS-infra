mock_provider "aws" {}
variables {
  required_repositories = ["playdevops/sample-app", "playdevops/mini-commerce"]
  configuration         = { ownership_mode = "terraform", scan_type = "ENHANCED", scan_frequency = "CONTINUOUS_SCAN", repository_filters = ["playdevops/sample-app*", "playdevops/mini-commerce*"] }
}
run "enhanced_continuous_scanning" {
  command = plan
  assert {
    condition     = aws_ecr_registry_scanning_configuration.this[0].scan_type == "ENHANCED" && one(aws_ecr_registry_scanning_configuration.this[0].rule).scan_frequency == "CONTINUOUS_SCAN"
    error_message = "Enhanced continuous registry scanning is required."
  }
}
run "rejects_basic" {
  command = plan
  variables { configuration = { ownership_mode = "terraform", scan_type = "BASIC", scan_frequency = "CONTINUOUS_SCAN", repository_filters = ["playdevops/sample-app*", "playdevops/mini-commerce*"] } }
  expect_failures = [var.configuration]
}
run "rejects_missing_migration_prefix" {
  command = plan
  variables { configuration = { ownership_mode = "terraform", scan_type = "ENHANCED", scan_frequency = "CONTINUOUS_SCAN", repository_filters = ["playdevops/mini-commerce*"] } }
  expect_failures = [var.configuration]
}
run "external_owner_creates_nothing" {
  command = plan
  variables { configuration = { ownership_mode = "external", scan_type = "ENHANCED", scan_frequency = "CONTINUOUS_SCAN", repository_filters = ["playdevops/sample-app*", "playdevops/mini-commerce*"] } }
  assert {
    condition     = length(aws_ecr_registry_scanning_configuration.this) == 0
    error_message = "Never overwrite external registry owner."
  }
}
