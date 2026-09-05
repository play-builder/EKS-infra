locals {
  namespace = "argocd"
  secret_specs = {
    oidc                  = { suffix = "oidc", target = "argocd-oidc", properties = { clientSecret = "clientSecret" } }
    notifications         = { suffix = "notifications", target = "argocd-notifications-secret", properties = { "pagerduty-integration-key" = "pagerdutyIntegrationKey", "slack-token" = "slackToken" } }
    repositoryCredentials = { suffix = "repository-credentials", target = "argocd-repository-credentials", properties = { url = "url", username = "username", password = "password" } }
  }
  rbac_policy = "g, ${var.platform.admin_group}, role:admin\ng, ${var.platform.readonly_group}, role:readonly\n"
  component   = { pdb = { enabled = var.environment == "prod", maxUnavailable = 1 }, resources = { requests = { cpu = "100m", memory = "128Mi" } } }
  values = {
    global = {
      image                     = { tag = "v3.5.2" }
      affinity                  = { podAntiAffinity = var.environment == "prod" ? "hard" : "soft" }
      topologySpreadConstraints = var.environment == "prod" ? [{ maxSkew = 1, topologyKey = "topology.kubernetes.io/zone", whenUnsatisfiable = "DoNotSchedule" }] : []
    }
    dex            = { enabled = false }
    "redis-ha"     = { enabled = var.platform.redis_ha, replicas = 3, topologySpreadConstraints = { enabled = var.environment == "prod", maxSkew = 1, topologyKey = "topology.kubernetes.io/zone", whenUnsatisfiable = "DoNotSchedule" } }
    server         = merge(local.component, { replicas = var.platform.server_replicas, service = { type = "ClusterIP" }, metrics = { enabled = true } })
    repoServer     = merge(local.component, { replicas = var.platform.repo_server_replicas })
    controller     = merge(local.component, { replicas = var.platform.controller_replicas, metrics = { enabled = true } })
    applicationSet = merge(local.component, { replicas = var.platform.applicationset_replicas })
    configs = {
      params = { "server.insecure" = true }
      cm = merge(var.health_customizations, {
        "admin.enabled" = "true"
        "url"           = var.platform.public_url
        "oidc.config"   = yamlencode({ name = "Corporate", issuer = var.platform.oidc_issuer_url, clientID = var.platform.oidc_client_id, clientSecret = "$argocd-oidc:clientSecret", requestedScopes = ["openid", "profile", "email", "groups"] })
      })
      rbac = { "policy.csv" = local.rbac_policy, "policy.default" = "role:readonly", scopes = "[groups]" }
    }
    notifications = {
      enabled = true
      secret  = { create = false, name = "argocd-notifications-secret" }
      notifiers = {
        "service.pagerdutyv2" = yamlencode({ serviceKeys = { "platform-prod" = "$pagerduty-integration-key" } })
        "service.slack"       = yamlencode({ token = "$slack-token" })
      }
      templates = {
        "template.platform-failure"  = yamlencode({ message = "Application {{.app.metadata.name}} is {{.app.status.health.status}} at {{.app.status.sync.revision}}", pagerdutyv2 = { summary = "Argo CD application failure", severity = "critical", source = "{{.app.metadata.name}}", component = "argocd", group = var.environment } })
        "template.platform-deployed" = yamlencode({ message = "Application {{.app.metadata.name}} deployed {{.app.status.sync.revision}}" })
      }
      triggers = {
        "trigger.on-sync-failed"         = yamlencode([{ when = "app.status.operationState != nil && app.status.operationState.phase in ['Error', 'Failed']", send = ["platform-failure"] }])
        "trigger.on-health-degraded"     = yamlencode([{ when = "app.status.health.status in ['Degraded', 'Unknown']", send = ["platform-failure"] }])
        "trigger.on-sync-status-unknown" = yamlencode([{ when = "app.status.sync.status == 'Unknown'", send = ["platform-failure"] }])
        "trigger.on-deployed"            = yamlencode([{ when = "app.status.operationState != nil && app.status.operationState.phase == 'Succeeded' && app.status.health.status == 'Healthy'", oncePer = "app.status.sync.revision", send = ["platform-deployed"] }])
      }
    }
  }
}
resource "aws_secretsmanager_secret" "argocd" {
  for_each                = local.secret_specs
  name                    = "${var.name}/argocd/${each.value.suffix}"
  recovery_window_in_days = 7
  tags                    = var.tags
  lifecycle { prevent_destroy = true }
}
resource "aws_iam_role" "secret_reader" {
  name = "${var.name}-argocd-secrets-reader"
  tags = var.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = { StringEquals = { "${var.oidc_provider}:aud" = "sts.amazonaws.com", "${var.oidc_provider}:sub" = "system:serviceaccount:argocd:argocd-secrets-reader" } }
    }]
  })
}
resource "aws_iam_role_policy" "secret_reader" {
  role   = aws_iam_role.secret_reader.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"], Resource = [for s in aws_secretsmanager_secret.argocd : s.arn] }] })
}
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.4.3"
  namespace        = local.namespace
  create_namespace = true
  atomic           = true
  timeout          = 900
  values           = [yamlencode(local.values)]
}
resource "kubectl_manifest" "secret_reader" {
  yaml_body  = yamlencode({ apiVersion = "v1", kind = "ServiceAccount", metadata = { name = "argocd-secrets-reader", namespace = local.namespace, annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.secret_reader.arn } } })
  depends_on = [helm_release.argocd]
}
resource "kubectl_manifest" "secret_store" {
  yaml_body  = yamlencode({ apiVersion = "external-secrets.io/v1", kind = "SecretStore", metadata = { name = "argocd-secrets", namespace = local.namespace }, spec = { provider = { aws = { service = "SecretsManager", region = var.region, auth = { jwt = { serviceAccountRef = { name = "argocd-secrets-reader" } } } } } } })
  depends_on = [kubectl_manifest.secret_reader, aws_iam_role_policy.secret_reader]
}
