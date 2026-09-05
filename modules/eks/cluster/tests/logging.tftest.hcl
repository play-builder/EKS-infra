mock_provider "aws" {}
variables {
  name                                 = "prod-course"
  cluster_name                         = "prod-course-eks"
  vpc_id                               = "vpc-12345678"
  public_subnet_ids                    = ["subnet-public"]
  private_subnet_ids                   = ["subnet-private"]
  cluster_endpoint_public_access_cidrs = []
  cluster_endpoint_public_access       = false
  vpc_cni_addon_version                = "v1.20.4-eksbuild.1"
  environment                          = "prod"
  cluster_log_retention_in_days        = 90
  cluster_log_kms_key_arn              = "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-2222-3333-4444-555555555555"
}
run "prod_rejects_short_audit_retention" {
  command = plan
  variables { cluster_log_retention_in_days = 30 }
  expect_failures = [var.cluster_log_retention_in_days]
}
run "prod_rejects_unencrypted_audit_logs" {
  command = plan
  variables { cluster_log_kms_key_arn = null }
  expect_failures = [var.cluster_log_kms_key_arn]
}
run "encrypted_group_retains_existing_address" {
  command = plan
  assert {
    condition     = aws_cloudwatch_log_group.cluster.kms_key_id == var.cluster_log_kms_key_arn && aws_cloudwatch_log_group.cluster.retention_in_days == 90
    error_message = "Existing control-plane group must use the network key and production retention."
  }
}
