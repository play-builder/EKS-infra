mock_provider "helm" {}

run "disabled_by_default" {
  command = plan

  assert {
    condition     = length(helm_release.this) == 0
    error_message = "k6 operator must be absent until Ch16 enables it."
  }
}

run "enabled_only_in_dedicated_dev_namespace" {
  command = plan

  variables {
    enable_k6_operator = true
    environment        = "dev"
    namespace          = "k6-operator-system"
    chart_version      = "4.6.0"
  }

  assert {
    condition = (
      length(helm_release.this) == 1 &&
      helm_release.this[0].namespace == "k6-operator-system"
    )
    error_message = "Enabled k6 operator must run in the dedicated controller namespace."
  }
}

run "prod_rejects_load_controller" {
  command = plan

  variables {
    enable_k6_operator = true
    environment        = "prod"
  }

  expect_failures = [var.enable_k6_operator]
}
