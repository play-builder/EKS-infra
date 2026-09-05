mock_provider "aws" {
  mock_resource "aws_cloudwatch_log_group" {
    override_during = plan
    defaults        = { arn = "arn:aws:logs:ap-northeast-2:123456789012:log-group:/aws/vpc/prod-course/flow-logs" }
  }
}
variables {
  name                           = "prod-course"
  environment                    = "prod"
  vpc_cidr                       = "10.1.0.0/16"
  availability_zones             = ["ap-northeast-2a", "ap-northeast-2b", "ap-northeast-2c"]
  public_subnet_cidrs            = ["10.1.1.0/24", "10.1.2.0/24", "10.1.3.0/24"]
  private_subnet_cidrs           = ["10.1.11.0/24", "10.1.12.0/24", "10.1.13.0/24"]
  eks_cluster_name               = "prod-course-eks"
  enable_nat_gateway             = true
  production_nat_topology        = "per_az"
  single_nat_gateway             = false
  one_nat_gateway_per_az         = true
  enable_vpc_flow_logs           = true
  vpc_flow_log_retention_in_days = 90
  vpc_flow_log_kms_key_arn       = "arn:aws:kms:ap-northeast-2:123456789012:key/11111111-2222-3333-4444-555555555555"
  tags                           = { PlatformInstanceId = "platform", Owner = "team", CostCenter = "cc", Environment = "prod", ManagedBy = "Other" }
}
run "reject_short_flow_retention" {
  command = plan
  variables { vpc_flow_log_retention_in_days = 30 }
  expect_failures = [var.vpc_flow_log_retention_in_days]
}
run "reject_unsupported_flow_retention" {
  command = plan
  variables { vpc_flow_log_retention_in_days = 91 }
  expect_failures = [var.vpc_flow_log_retention_in_days]
}
run "reject_missing_prod_key" {
  command = plan
  variables { vpc_flow_log_kms_key_arn = null }
  expect_failures = [var.vpc_flow_log_kms_key_arn]
}
run "existing_flow_destination_and_policy_are_protected" {
  command = plan
  assert {
    condition     = aws_cloudwatch_log_group.vpc_flow[0].kms_key_id == var.vpc_flow_log_kms_key_arn && aws_cloudwatch_log_group.vpc_flow[0].retention_in_days == 90 && aws_cloudwatch_log_group.vpc_flow[0].tags.ManagedBy == "Terraform" && aws_iam_role.vpc_flow[0].tags.ManagedBy == "Terraform" && aws_flow_log.vpc[0].tags.ManagedBy == "Terraform"
    error_message = "Existing Flow Log group, role and flow resource must keep exact encryption/retention/ownership."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.vpc_flow_delivery[0].policy).Statement[1].Resource == "arn:aws:logs:ap-northeast-2:123456789012:log-group:/aws/vpc/prod-course/flow-logs:log-stream:*" && jsondecode(aws_iam_role_policy.vpc_flow_delivery[0].policy).Statement[2].Resource == var.vpc_flow_log_kms_key_arn && jsondecode(aws_iam_role_policy.vpc_flow_delivery[0].policy).Statement[2].Condition.StringEquals["kms:ViaService"] == "logs.ap-northeast-2.amazonaws.com" && jsondecode(aws_iam_role_policy.vpc_flow_delivery[0].policy).Statement[2].Condition.ArnEquals["kms:EncryptionContext:aws:logs:arn"] == "arn:aws:logs:ap-northeast-2:123456789012:log-group:/aws/vpc/prod-course/flow-logs"
    error_message = "Flow delivery must constrain stream actions and KMS key/context/ViaService."
  }
}
