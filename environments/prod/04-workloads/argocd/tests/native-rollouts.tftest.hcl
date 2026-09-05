mock_provider "aws" {}
mock_provider "helm" {}
mock_provider "kubectl" {}
override_data {
  target = data.terraform_remote_state.eks
  values = { outputs = { cluster_name = "fixture", cluster_endpoint = "https://fixture.invalid", cluster_certificate_authority_data = "Y2E=", oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/fixture", oidc_provider = "oidc.eks.ap-northeast-2.amazonaws.com/id/fixture" } }
}
override_data {
  target = data.terraform_remote_state.platform
  values = { outputs = { rollouts_amp_role_arn = null } }
}
variables {
  state_bucket_name = "course-state"
  aws_region        = "ap-northeast-2"
  gitops_repo_url   = "https://github.com/play-builder/argocd-gitops.git"
  tags              = { PlatformInstanceId = "fixture", Owner = "platform", CostCenter = "engineering", Environment = "spoofed", ManagedBy = "spoofed", CourseId = "spoofed" }
  argocd_platform   = { server_replicas = 2, repo_server_replicas = 2, controller_replicas = 2, applicationset_replicas = 2, redis_ha = true, node_count = 3, az_count = 3, public_url = "https://argocd.example.invalid", oidc_issuer_url = "https://id.example.invalid", oidc_client_id = "argocd", admin_group = "admins", readonly_group = "readers" }
}
run "native_istio_only" {
  command = plan
  assert {
    condition     = try(yamldecode(helm_release.argo_rollouts.values[0]).providerRBAC.providers.istio, false) && !try(yamldecode(helm_release.argo_rollouts.values[0]).providerRBAC.providers.gatewayAPI, true) && !can(yamldecode(helm_release.argo_rollouts.values[0]).controller.trafficRouterPlugins)
    error_message = "Use the native Istio provider; no Gateway API traffic plugin."
  }
  assert {
    condition     = !can(module.argocd.helm_values.configs.cm["resource.customizations.ignoreDifferences.gateway.networking.k8s.io_HTTPRoute"])
    error_message = "Do not ignore an entire HTTPRoute spec."
  }
}
