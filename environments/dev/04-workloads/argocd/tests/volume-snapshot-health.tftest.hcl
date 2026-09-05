mock_provider "aws" {}
mock_provider "helm" {}
mock_provider "kubectl" {}

override_data {
  target = data.terraform_remote_state.eks
  values = {
    outputs = {
      oidc_provider_arn                  = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/fixture"
      oidc_provider                      = "oidc.eks.ap-northeast-2.amazonaws.com/id/fixture"
      cluster_name                       = "dev-course"
      cluster_endpoint                   = "https://eks.example.invalid"
      cluster_certificate_authority_data = "Y2E="
    }
  }
}

override_data {
  target = data.terraform_remote_state.platform
  values = { outputs = { rollouts_amp_role_arn = null } }
}

run "volume_snapshot_health_is_terraform_owned" {
  command = plan

  variables {
    tags              = { PlatformInstanceId = "fixture", Owner = "platform", CostCenter = "engineering", Environment = "dev" }
    argocd_platform   = { server_replicas = 2, repo_server_replicas = 2, controller_replicas = 2, applicationset_replicas = 2, redis_ha = true, node_count = 3, az_count = 3, public_url = "https://argocd.example.invalid", oidc_issuer_url = "https://id.example.invalid", oidc_client_id = "argocd", admin_group = "admins", readonly_group = "readers" }
    aws_region        = "ap-northeast-2"
    gitops_repo_url   = "https://github.com/play-builder/argocd-gitops.git"
    state_bucket_name = "course-dev-state"
  }

  assert {
    condition = (
      module.argocd.helm_values.configs.cm["course.health.volume-snapshot.contract"] == "volume-snapshot-ready-health/v1" &&
      strcontains(module.argocd.helm_values.configs.cm["resource.customizations.health.snapshot.storage.k8s.io_VolumeSnapshot"], "obj.status.readyToUse == true") &&
      strcontains(module.argocd.helm_values.configs.cm["resource.customizations.health.snapshot.storage.k8s.io_VolumeSnapshot"], "obj.status.error ~= nil") &&
      strcontains(module.argocd.helm_values.configs.cm["resource.customizations.health.snapshot.storage.k8s.io_VolumeSnapshot"], "Progressing")
    )
    error_message = "Terraform-owned argocd-cm must implement the VolumeSnapshot health contract."
  }
}

variables {
  state_bucket_name = "course-state"
}
