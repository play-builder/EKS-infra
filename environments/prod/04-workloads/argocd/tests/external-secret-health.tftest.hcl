mock_provider "aws" {}
mock_provider "helm" {}
mock_provider "kubectl" {}

override_data {
  target = data.terraform_remote_state.eks
  values = {
    outputs = {
      cluster_name                       = "prod-course"
      cluster_endpoint                   = "https://eks.example.invalid"
      cluster_certificate_authority_data = "Y2E="
    }
  }
}

override_data {
  target = data.terraform_remote_state.platform
  values = { outputs = { rollouts_amp_role_arn = null } }
}

run "external_secret_health_is_generation_aware" {
  command = plan

  variables {
    aws_region        = "ap-northeast-2"
    state_bucket_name = "course-prod-state"
    gitops_repo_url   = "https://github.com/play-builder/argocd-gitops.git"
  }

  assert {
    condition = (
      yamldecode(helm_release.argocd.values[0]).configs.cm["course.health.external-secret.contract"] == "external-secret-ready-health/v1" &&
      strcontains(yamldecode(helm_release.argocd.values[0]).configs.cm["resource.customizations.health.external-secrets.io_ExternalSecret"], "observedGeneration") &&
      strcontains(yamldecode(helm_release.argocd.values[0]).configs.cm["resource.customizations.health.external-secrets.io_ExternalSecret"], "observed == nil") &&
      strcontains(yamldecode(helm_release.argocd.values[0]).configs.cm["resource.customizations.health.external-secrets.io_ExternalSecret"], "condition.status == \"True\"") &&
      strcontains(yamldecode(helm_release.argocd.values[0]).configs.cm["resource.customizations.health.external-secrets.io_ExternalSecret"], "condition.status == \"False\"")
    )
    error_message = "Argo CD must own the generation-aware ExternalSecret Ready health contract."
  }
}
