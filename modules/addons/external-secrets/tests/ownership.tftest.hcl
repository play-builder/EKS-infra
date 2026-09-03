mock_provider "helm" {}

run "stable_release_can_be_adopted_without_secret_values" {
  command = plan

  variables {
    chart_version = "2.10.0"
  }

  assert {
    condition = (
      helm_release.this.name == "external-secrets" &&
      helm_release.this.namespace == "external-secrets" &&
      helm_release.this.chart == "external-secrets" &&
      yamldecode(helm_release.this.values[0]).installCRDs == true &&
      length(keys(yamldecode(helm_release.this.values[0]))) == 3
    )
    error_message = "External Secrets must keep the stable import identity and contain controller settings only."
  }
}
