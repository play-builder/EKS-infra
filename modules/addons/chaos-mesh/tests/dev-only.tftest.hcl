mock_provider "helm" {}

run "disabled_by_default" {
  command = plan

  variables {
    enable_chaos_mesh = false
    environment       = "dev"
  }

  assert {
    condition     = length(helm_release.this) == 0
    error_message = "Chaos Mesh must remain absent until Ch25 explicitly enables it."
  }
}

run "enabled_only_for_dev_with_bounded_settings" {
  command = plan

  variables {
    enable_chaos_mesh          = true
    course_id                  = "course-2026"
    environment                = "dev"
    namespace                  = "chaos-mesh"
    allowed_namespaces         = ["app-dev"]
    max_fault_duration_seconds = 60
    max_faults                 = 1
    chart_version              = "2.8.0"
  }

  assert {
    condition = (
      length(helm_release.this) == 1 &&
      helm_release.this[0].namespace == "chaos-mesh" &&
      yamldecode(helm_release.this[0].values[0]).controllerManager.enableFilterNamespace == true &&
      yamldecode(helm_release.this[0].values[0]).controllerManager.targetNamespace == "app-dev" &&
      yamldecode(helm_release.this[0].values[0]).course.courseId == "course-2026" &&
      yamldecode(helm_release.this[0].values[0]).course.maxFaultDurationSeconds == 60 &&
      yamldecode(helm_release.this[0].values[0]).course.maxFaults == 1
    )
    error_message = "Enabled Chaos Mesh must carry namespace filtering and bounded fault metadata."
  }
}

run "prod_rejects_chaos_mesh" {
  command = plan

  variables {
    enable_chaos_mesh = true
    environment       = "prod"
  }

  expect_failures = [var.enable_chaos_mesh]
}
