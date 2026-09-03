mock_provider "aws" {}
mock_provider "helm" {}
mock_provider "kubectl" {}

override_data {
  target = data.terraform_remote_state.eks
  values = {
    outputs = {
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
    aws_region       = "ap-northeast-2"
    state_bucket_name = "course-dev-state"
    gitops_repo_url  = "https://github.com/play-builder/argocd-gitops.git"
  }

  assert {
    condition = (
      yamldecode(helm_release.argocd.values[0]).configs.cm["course.health.volume-snapshot.contract"] == "volume-snapshot-ready-health/v1" &&
      strcontains(yamldecode(helm_release.argocd.values[0]).configs.cm["resource.customizations.health.snapshot.storage.k8s.io_VolumeSnapshot"], "obj.status.readyToUse == true") &&
      strcontains(yamldecode(helm_release.argocd.values[0]).configs.cm["resource.customizations.health.snapshot.storage.k8s.io_VolumeSnapshot"], "obj.status.error ~= nil") &&
      strcontains(yamldecode(helm_release.argocd.values[0]).configs.cm["resource.customizations.health.snapshot.storage.k8s.io_VolumeSnapshot"], "Progressing")
    )
    error_message = "Terraform-owned argocd-cm must implement the VolumeSnapshot health contract."
  }
}
