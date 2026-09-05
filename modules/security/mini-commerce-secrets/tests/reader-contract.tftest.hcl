mock_provider "aws" {
  mock_resource "aws_secretsmanager_secret" { defaults = { arn = "arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:fixture-AbCdEf" } }
  mock_resource "aws_iam_role" { defaults = { arn = "arn:aws:iam::123456789012:role/fixture" } }
}
variables {
  name              = "prod-fixture"
  namespace         = "app-prod"
  region            = "ap-northeast-2"
  oidc_provider     = "oidc.eks.ap-northeast-2.amazonaws.com/id/FIXTURE"
  oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.ap-northeast-2.amazonaws.com/id/FIXTURE"
  tags              = { PlatformInstanceId = "fixture", Owner = "fixture", CostCenter = "fixture", Environment = "prod" }
}
run "split_reader_scope" {
  command = apply
  assert {
    condition     = length(jsondecode(aws_iam_role_policy.reader["runtime"].policy).Statement[0].Resource) == 2 && length(jsondecode(aws_iam_role_policy.reader["migration"].policy).Statement[0].Resource) == 1
    error_message = "Runtime reader gets runtime+DML only; migration gets DDL only."
  }
  assert {
    condition     = jsondecode(aws_iam_role.reader["migration"].assume_role_policy).Statement[0].Condition.StringEquals["oidc.eks.ap-northeast-2.amazonaws.com/id/FIXTURE:sub"] == "system:serviceaccount:app-prod:mini-commerce-migration-secrets-reader"
    error_message = "Migration has a separate exact ServiceAccount."
  }
}
