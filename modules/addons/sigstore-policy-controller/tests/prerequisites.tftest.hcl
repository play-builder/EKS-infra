mock_provider "helm" {}
mock_provider "kubectl" {}
mock_provider "aws" {
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::123456789012:role/fixture" } }
}
variables {
  environment        = "prod"
  name               = "fixture"
  replicas           = 2
  oidc_provider      = "oidc.eks.ap-northeast-2.amazonaws.com/id/FIXTURE"
  oidc_provider_arn  = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/FIXTURE"
  repository_arns    = ["arn:aws:ecr:ap-northeast-2:123456789012:repository/playdevops/mini-commerce"]
  api_server_cidrs   = ["10.0.1.2/32"]
  https_egress_cidrs = ["192.0.2.10/32"]
  tags               = { PlatformInstanceId = "fixture", Owner = "fixture", CostCenter = "fixture", Environment = "prod" }
}
run "pinned_fail_closed_webhook" {
  command = apply
  assert {
    condition     = local.values.webhook.failurePolicy == "Fail" && local.values.webhook.replicaCount == 2 && local.values.webhook.podDisruptionBudget.minAvailable == 1 && strcontains(local.values.leasescleanup.image.version, "@sha256:")
    error_message = "Controller must fail closed, be available and pin cleanup image."
  }
}
run "rejects_single_replica_prod" {
  command = plan
  variables { replicas = 1 }
  expect_failures = [var.replicas]
}
run "rejects_unbounded_egress" {
  command = plan
  variables { https_egress_cidrs = ["0.0.0.0/0"] }
  expect_failures = [var.https_egress_cidrs]
}
