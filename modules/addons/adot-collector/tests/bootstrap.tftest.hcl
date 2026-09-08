mock_provider "aws" {}
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}

variables {
  eks_cluster_name       = "dev-mini-commerce-eks"
  environment            = "dev"
  aws_region             = "ap-northeast-2"
  oidc_provider_arn      = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/TEST"
  oidc_provider          = "oidc.eks.ap-northeast-2.amazonaws.com/id/TEST"
  addon_version          = "v1.0.0-eksbuild.1" # Synthetic input, not an AWS compatibility claim.
  amp_workspace_endpoint = "https://aps-workspaces.ap-northeast-2.amazonaws.com/workspaces/ws-test/"
  amp_workspace_arn      = "arn:aws:aps:ap-northeast-2:123456789012:workspace/ws-test"
}

run "collector_bootstrap_plan" {
  command = plan

  assert {
    condition     = aws_eks_addon.adot.addon_version == var.addon_version
    error_message = "The approved add-on version must reach the EKS resource."
  }
  assert {
    condition     = length(kubectl_manifest.otel_collector) == 1
    error_message = "An enabled collector must be planned without querying a live CRD schema."
  }
  assert {
    condition     = !yamldecode(kubectl_manifest.otel_collector[0].yaml_body).spec.config.receivers.prometheus.config.scrape_configs[2].tls_config.insecure_skip_verify
    error_message = "The API-server proxy scrape must verify the service-account CA."
  }
}

run "operator_only" {
  command = plan
  variables {
    enable_collection      = false
    amp_workspace_endpoint = ""
  }
  assert {
    condition     = length(kubectl_manifest.otel_collector) == 0 && length(kubernetes_service_account_v1.adot_collector) == 0
    error_message = "The explicit plan-time switch must control collector resources."
  }
}

run "reject_unpinned_addon" {
  command = plan
  variables { addon_version = "latest" }
  expect_failures = [var.addon_version]
}

run "reject_missing_metrics_destination" {
  command = plan
  variables { amp_workspace_endpoint = "" }
  expect_failures = [var.amp_workspace_endpoint]
}
