output "release_name" { value = helm_release.argocd.name }
output "helm_values" { value = local.values }
output "argocd" {
  value = merge({
    namespace         = local.namespace
    chartVersion      = "10.4.3"
    controllerVersion = "v3.5.2"
    haEnabled         = var.platform.redis_ha && min(var.platform.server_replicas, var.platform.repo_server_replicas, var.platform.controller_replicas, var.platform.applicationset_replicas) >= 2
    bootstrapMode     = "public"
    secretStore       = { name = "argocd-secrets", kind = "SecretStore", namespace = local.namespace, region = var.region, serviceAccountName = "argocd-secrets-reader", roleArn = aws_iam_role.secret_reader.arn }
    rbacPolicyHash    = sha256(local.rbac_policy)
    }, {
    for key, s in local.secret_specs : key => merge({
      sourceArn  = aws_secretsmanager_secret.argocd[key].arn
      sourceName = aws_secretsmanager_secret.argocd[key].name
      targetName = s.target
      properties = s.properties
    }, key == "oidc" ? { clientSecretRef = "$argocd-oidc:clientSecret" } : {}, key == "notifications" ? { routes = { paging = { service = "pagerdutyv2", recipient = "platform-prod" }, deployment = { service = "slack", recipient = "platform-deployments", secretKey = "slack-token" } } } : {})
  })
}
