output "secrets" {
  value = {
    namespace      = var.namespace
    consumerStatus = "PENDING_GITOPS_CUTOVER"
    sources        = { for k, s in local.specs : k => { sourceName = aws_secretsmanager_secret.this[k].name, sourceArn = aws_secretsmanager_secret.this[k].arn, targetName = s.target, properties = s.properties } }
    readers        = { for k, r in local.readers : k => { serviceAccountName = r.service_account, roleArn = aws_iam_role.reader[k].arn, secretStore = { name = r.store, kind = "SecretStore", namespace = var.namespace, region = var.region } } }
  }
}
output "application_credentials" {
  value = { for k in ["database", "migration"] : k => { name = aws_secretsmanager_secret.this[k].name, arn = aws_secretsmanager_secret.this[k].arn } }
}
