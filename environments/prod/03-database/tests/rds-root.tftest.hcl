mock_provider "aws" {
  mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }
  mock_data "aws_region" { defaults = { name = "us-east-1" } }
  mock_data "aws_secretsmanager_secret" { defaults = { name = "prod/mini-commerce/database", arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:prod/mini-commerce/database-abcdef" } }
  mock_data "aws_eks_cluster" { defaults = { arn = "arn:aws:eks:us-east-1:123456789012:cluster/rebuilt", identity = [{ oidc = [{ issuer = "https://oidc.eks.us-east-1.amazonaws.com/id/NEW" }] }] } }
  mock_data "aws_iam_openid_connect_provider" { defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/NEW" } }
}
override_module {
  target  = module.database
  outputs = { database_contract = { schemaVersion = "platform.database/v1" } }
}
override_data {
  target = data.terraform_remote_state.network
  values = { outputs = { vpc_id = "vpc-0123456789abcdef0", vpc_arn = "arn:aws:ec2:us-east-1:123456789012:vpc/vpc-0123456789abcdef0", database_subnet_ids = ["subnet-0123456789abcdef0", "subnet-1123456789abcdef0"], private_subnet_ids = ["subnet-2123456789abcdef0"] } }
}
override_data {
  target = data.terraform_remote_state.platform
  values = { outputs = { application_credentials = {
    database  = { name = "prod/mini-commerce/database", arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:prod/mini-commerce/database-abcdef" },
    migration = { name = "prod/mini-commerce/migration", arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:prod/mini-commerce/migration-abcdef" }
  } } }
}
variables {
  expected_account_id       = "123456789012"
  aws_region                = "us-east-1"
  state_bucket              = "prod-state"
  state_region              = "us-east-1"
  identifier                = "commerce-target"
  engine_version            = "17.6"
  instance_class            = "db.m7g.large"
  ca_cert_identifier        = "rds-ca-rsa2048-g1"
  client_security_group_ids = ["sg-0123456789abcdef0"]
  final_snapshot_identifier = "commerce-target-final-test"
  tags                      = { PlatformInstanceId = "test", Owner = "platform", CostCenter = "cc", Environment = "prod" }
}
run "rejects_wrong_account" {
  command = plan
  variables { expected_account_id = "999999999999" }
  expect_failures = [terraform_data.identity]
}
run "rejects_wrong_region" {
  command = plan
  variables { aws_region = "eu-west-1" }
  expect_failures = [terraform_data.identity]
}
run "rejects_application_subnets" {
  command = plan
  override_data {
    target = data.terraform_remote_state.network
    values = { outputs = { vpc_id = "vpc-0123456789abcdef0", vpc_arn = "arn:aws:ec2:us-east-1:123456789012:vpc/vpc-0123456789abcdef0", database_subnet_ids = ["subnet-2123456789abcdef0"], private_subnet_ids = ["subnet-2123456789abcdef0"] } }
  }
  expect_failures = [terraform_data.identity]
}

override_data {
  target = data.aws_secretsmanager_secret.application["migration"]
  values = { name = "prod/mini-commerce/migration", arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:prod/mini-commerce/migration-abcdef" }
}
run "production_state_contract" {
  command = apply
  assert {
    condition     = output.database_contract.root.stateKey == "prod/03-database/terraform.tfstate" && output.database_contract.applicationCredentials.database.name == "prod/mini-commerce/database"
    error_message = "Production must consume platform credential shells in its own state."
  }
}
