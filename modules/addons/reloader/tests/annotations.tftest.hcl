mock_provider "helm" {}

run "reloader_uses_annotation_reload_for_rollouts" {
  command = plan

  variables {
    chart_version = "2.2.16"
  }

  assert {
    condition = (
      yamldecode(helm_release.this.values[0]).reloader.reloadStrategy == "annotations" &&
      yamldecode(helm_release.this.values[0]).reloader.isArgoRollouts == true
    )
    error_message = "Reloader must use annotation reload strategy with Argo Rollouts integration."
  }
}
