mock_provider "aws" {}
variables {
  cluster_name           = "fixture"
  managed_addon_versions = { coredns = "v1.0.0-eksbuild.1", kube_proxy = "v1.36.0-eksbuild.1" }
  tags                   = { PlatformInstanceId = "fixture", Owner = "fixture", CostCenter = "fixture", Environment = "dev" }
}
run "owns_only_dns_and_proxy" {
  command = plan
  assert {
    condition     = aws_eks_addon.coredns.addon_name == "coredns" && aws_eks_addon.kube_proxy.addon_name == "kube-proxy"
    error_message = "Add-on ownership changed."
  }
}
run "rejects_empty_dns" {
  command = plan
  variables { managed_addon_versions = { coredns = "", kube_proxy = "v1.36.0-eksbuild.1" } }
  expect_failures = [var.managed_addon_versions]
}
run "rejects_empty_proxy" {
  command = plan
  variables { managed_addon_versions = { coredns = "v1.0.0-eksbuild.1", kube_proxy = "" } }
  expect_failures = [var.managed_addon_versions]
}
