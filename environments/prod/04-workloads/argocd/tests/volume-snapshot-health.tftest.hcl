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

run "volume_snapshot_health_and_manual_bootstrap" {
  command = plan

  variables {
    aws_region       = "us-east-1"
    gitops_repo_url  = "https://github.com/play-builder/argocd-gitops.git"
    enable_bootstrap = true
  }

  assert {
    condition = (
      yamldecode(helm_release.argocd.values[0]).configs.cm["course.health.volume-snapshot.contract"] == "volume-snapshot-ready-health/v1" &&
      strcontains(yamldecode(helm_release.argocd.values[0]).configs.cm["resource.customizations.health.snapshot.storage.k8s.io_VolumeSnapshot"], "obj.status.readyToUse == true") &&
      strcontains(yamldecode(helm_release.argocd.values[0]).configs.cm["resource.customizations.health.snapshot.storage.k8s.io_VolumeSnapshot"], "obj.status.error ~= nil")
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
