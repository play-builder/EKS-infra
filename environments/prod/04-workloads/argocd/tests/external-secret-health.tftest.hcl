mock_provider "aws" {}
mock_provider "helm" {}
mock_provider "kubectl" {}

override_data {
  target = data.terraform_remote_state.eks
  values = {
    outputs = {
      oidc_provider_arn                  = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/fixture"
      oidc_provider                      = "oidc.eks.ap-northeast-2.amazonaws.com/id/fixture"
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
    tags              = { PlatformInstanceId = "fixture", Owner = "platform", CostCenter = "engineering", Environment = "prod" }
    argocd_platform   = { server_replicas = 2, repo_server_replicas = 2, controller_replicas = 2, applicationset_replicas = 2, redis_ha = true, node_count = 3, az_count = 3, public_url = "https://argocd.example.invalid", oidc_issuer_url = "https://id.example.invalid", oidc_client_id = "argocd", admin_group = "admins", readonly_group = "readers" }
    aws_region        = "ap-northeast-2"
    gitops_repo_url   = "https://github.com/play-builder/argocd-gitops.git"
    state_bucket_name = "course-prod-state"
  }

  assert {
    condition = (
      module.argocd.helm_values.configs.cm["course.health.external-secret.contract"] == "external-secret-ready-health/v1" &&
      !strcontains(module.argocd.helm_values.configs.cm["resource.customizations.health.external-secrets.io_ExternalSecret"], "observedGeneration") &&
      strcontains(module.argocd.helm_values.configs.cm["resource.customizations.health.external-secrets.io_ExternalSecret"], "syncedResourceVersion") &&
      strcontains(module.argocd.helm_values.configs.cm["resource.customizations.health.external-secrets.io_ExternalSecret"], "condition.status == \"True\"") &&
      strcontains(module.argocd.helm_values.configs.cm["resource.customizations.health.external-secrets.io_ExternalSecret"], "condition.status == \"False\"")
    )
    error_message = "Argo CD must own the generation-aware ExternalSecret Ready health contract."
  }
}

variables {
  state_bucket_name = "course-state"
}
