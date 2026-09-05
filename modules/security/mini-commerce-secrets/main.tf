locals {
  specs = {
    runtime   = { target = "mini-commerce-runtime", properties = { API_KEY = "API_KEY" } }
    database  = { target = "mini-commerce-database", properties = { DB_HOST = "DB_HOST", DB_PORT = "DB_PORT", DB_NAME = "DB_NAME", DB_USER = "DB_USER", DB_PASSWORD = "DB_PASSWORD" } }
    migration = { target = "mini-commerce-migration", properties = { DB_HOST = "DB_HOST", DB_PORT = "DB_PORT", DB_NAME = "DB_NAME", DB_USER = "DB_USER", DB_PASSWORD = "DB_PASSWORD" } }
  }
  readers = {
    runtime   = { service_account = "mini-commerce-secrets-reader", secrets = ["runtime", "database"], store = "mini-commerce-secrets" }
    migration = { service_account = "mini-commerce-migration-secrets-reader", secrets = ["migration"], store = "mini-commerce-migration-secrets" }
  }
}
resource "aws_secretsmanager_secret" "this" {
  for_each                = local.specs
  name                    = "${var.name}/mini-commerce/${each.key}"
  recovery_window_in_days = 7
  tags                    = var.tags
  lifecycle { prevent_destroy = true }
}
resource "aws_iam_role" "reader" {
  for_each = local.readers
  name     = "${var.name}-${each.value.service_account}"
  tags     = var.tags
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Allow", Action = "sts:AssumeRoleWithWebIdentity", Principal = { Federated = var.oidc_provider_arn },
    Condition = { StringEquals = { "${var.oidc_provider}:aud" = "sts.amazonaws.com", "${var.oidc_provider}:sub" = "system:serviceaccount:${var.namespace}:${each.value.service_account}" } }
  }] })
}
resource "aws_iam_role_policy" "reader" {
  for_each = local.readers
  role     = aws_iam_role.reader[each.key].id
  policy   = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"], Resource = [for k in each.value.secrets : aws_secretsmanager_secret.this[k].arn] }] })
}
