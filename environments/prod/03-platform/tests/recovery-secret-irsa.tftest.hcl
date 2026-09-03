mock_provider "aws" {}
mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "kubectl" {}
mock_provider "http" {}

variables {
  aws_region                      = "ap-northeast-2"
  acm_domain_name                 = "example.com"
  hosted_zone_id                  = "Z0123456789"
  enable_gateway_api              = false
  enable_ebs_csi_driver           = false
  enable_alb_controller           = false
  enable_external_dns             = false
  enable_metrics_server           = false
  enable_adot_collector           = false
  enable_amp                      = false
  enable_external_secrets         = false
  external_secrets_ownership_mode = "fresh"
  enable_recovery_secret_reader   = true
}

run "prod_rejects_recovery_secret_role" {
  command = plan

  expect_failures = [var.enable_recovery_secret_reader]
}
