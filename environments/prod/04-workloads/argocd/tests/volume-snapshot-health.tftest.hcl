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

run "volume_snapshot_health_and_manual_bootstrap" {
  command = plan

  variables {
    tags             = { PlatformInstanceId = "fixture", Owner = "platform", CostCenter = "engineering", Environment = "prod" }
    argocd_platform  = { server_replicas = 2, repo_server_replicas = 2, controller_replicas = 2, applicationset_replicas = 2, redis_ha = true, node_count = 3, az_count = 3, public_url = "https://argocd.example.invalid", oidc_issuer_url = "https://id.example.invalid", oidc_client_id = "argocd", admin_group = "admins", readonly_group = "readers" }
    aws_region       = "us-east-1"
    gitops_repo_url  = "https://github.com/play-builder/argocd-gitops.git"
    enable_bootstrap = true
  }

  assert {
    condition = (
      module.argocd.helm_values.configs.cm["course.health.volume-snapshot.contract"] == "volume-snapshot-ready-health/v1" &&
      strcontains(module.argocd.helm_values.configs.cm["resource.customizations.health.snapshot.storage.k8s.io_VolumeSnapshot"], "obj.status.readyToUse == true") &&
      strcontains(module.argocd.helm_values.configs.cm["resource.customizations.health.snapshot.storage.k8s.io_VolumeSnapshot"], "obj.status.error ~= nil")
    )
    error_message = "Prod must use the Terraform-owned VolumeSnapshot health contract."
  }

  assert {
    condition = (
      !can(yamldecode(kubectl_manifest.bootstrap[0].yaml_body).spec.syncPolicy.automated) &&
      yamldecode(kubectl_manifest.bootstrap[0].yaml_body).spec.syncPolicy.syncOptions == ["CreateNamespace=true", "ServerSideApply=true"]
    )
    error_message = "Prod bootstrap must be manual and must not render syncPolicy.automated."
  }
}
