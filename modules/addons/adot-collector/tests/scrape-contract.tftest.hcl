mock_provider "aws" {}
mock_provider "helm" {}
mock_provider "kubernetes" {}
variables {
  eks_cluster_name       = "test-dev"
  aws_region             = "ap-northeast-2"
  oidc_provider_arn      = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/TEST"
  oidc_provider          = "oidc.eks.ap-northeast-2.amazonaws.com/id/TEST"
  amp_workspace_endpoint = "https://aps-workspaces.ap-northeast-2.amazonaws.com/workspaces/ws-test/"
  amp_workspace_arn      = "arn:aws:aps:ap-northeast-2:123456789012:workspace/ws-test"
  enable_xray            = true
}
run "separate_scrape_without_annotation_merge" {
  command = apply
  assert {
    condition     = try(kubernetes_manifest.otel_collector[0].manifest.spec.config.receivers.prometheus.config.scrape_configs[0].job_name == "mini-commerce-management" && kubernetes_manifest.otel_collector[0].manifest.spec.config.receivers.prometheus.config.scrape_configs[1].metrics_path == "/stats/prometheus", false)
    error_message = "Application and proxy targets must be scraped separately."
  }
}
