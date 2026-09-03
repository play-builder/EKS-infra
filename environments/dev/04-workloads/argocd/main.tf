data "terraform_remote_state" "eks" {
  backend = "s3"

  config = {
    bucket = "${var.project_name}-infra-tf-${var.environment}"
    key    = "${var.environment}/02-eks/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "platform" {
  backend = "s3"

  config = {
    bucket = "${var.project_name}-infra-tf-${var.environment}"
    key    = "${var.environment}/03-platform/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  bootstrap_path = var.bootstrap_path != "" ? var.bootstrap_path : "argocd/bootstrap/${var.environment}"
  rollouts_annotations = try(data.terraform_remote_state.platform.outputs.rollouts_amp_role_arn, null) != null ? {
    "eks.amazonaws.com/role-arn" = data.terraform_remote_state.platform.outputs.rollouts_amp_role_arn
  } : {}
  external_secret_health_lua = <<-LUA
    hs = {}
    hs.status = "Progressing"
    hs.message = "waiting for ExternalSecret Ready condition"
    if obj.status ~= nil and obj.status.conditions ~= nil then
      for _, condition in ipairs(obj.status.conditions) do
        if condition.type == "Ready" then
          local observed = condition.observedGeneration
          if observed == nil then observed = obj.status.observedGeneration end
          if observed == nil or obj.metadata == nil then
            hs.status = "Progressing"
            hs.message = "Ready condition has no observed generation"
          elseif observed ~= obj.metadata.generation then
            hs.status = "Progressing"
            hs.message = "Ready condition is stale"
          elseif condition.status == "True" then
            hs.status = "Healthy"
            hs.message = condition.message or "ExternalSecret is Ready"
          elseif condition.status == "False" then
            hs.status = "Degraded"
            hs.message = condition.message or "ExternalSecret is not Ready"
          end
          return hs
        end
      end
    end
    return hs
  LUA
  volume_snapshot_health_lua = <<-LUA
    hs = {}
    hs.status = "Progressing"
    hs.message = "waiting for VolumeSnapshot readiness"
    if obj.status ~= nil then
      if obj.status.error ~= nil then
        hs.status = "Degraded"
        hs.message = obj.status.error.message or "VolumeSnapshot reported an error"
      elseif obj.status.readyToUse == true then
        hs.status = "Healthy"
        hs.message = "VolumeSnapshot is ready to use"
      end
    end
    return hs
  LUA
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true
  atomic           = true
  timeout          = 900

  values = [
    yamlencode({
      configs = {
        params = {
          "server.insecure" = true
        }
        cm = {
          "course.health.external-secret.contract"                                        = "external-secret-ready-health/v1"
          "resource.customizations.health.external-secrets.io_ExternalSecret"             = local.external_secret_health_lua
          "course.health.volume-snapshot.contract"                                        = "volume-snapshot-ready-health/v1"
          "resource.customizations.health.snapshot.storage.k8s.io_VolumeSnapshot"         = local.volume_snapshot_health_lua
          "resource.customizations.ignoreDifferences.gateway.networking.k8s.io_HTTPRoute" = <<-YAML
            jqPathExpressions:
              - 'select(.metadata.labels["rollouts.argoproj.io/gatewayapi-canary"] == "in-progress") | .spec.rules'
          YAML
        }
      }
      server = {
        service = {
          type = "ClusterIP"
        }
        metrics = {
          enabled = true
        }
      }
      controller = {
        metrics = {
          enabled = true
        }
      }
    })
  ]
}

resource "helm_release" "argo_rollouts" {
  name             = "argo-rollouts"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-rollouts"
  version          = var.argo_rollouts_chart_version
  namespace        = "argo-rollouts"
  create_namespace = true
  atomic           = true
  timeout          = 900

  values = [
    yamlencode({
      controller = {
        serviceAccount = {
          create      = true
          name        = "argo-rollouts"
          annotations = local.rollouts_annotations
        }
        initContainers = [
          {
            name    = "copy-gateway-api-plugin"
            image   = "ghcr.io/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi:v${var.gateway_plugin_version}@${var.gateway_plugin_digest}"
            command = ["/bin/sh", "-c"]
            args    = ["cp /bin/rollouts-plugin-trafficrouter-gatewayapi /plugins/"]
            volumeMounts = [
              {
                name      = "gateway-api-plugin"
                mountPath = "/plugins"
              }
            ]
          }
        ]
        trafficRouterPlugins = [
          {
            name     = "argoproj-labs/gatewayAPI"
            location = "file:///plugins/rollouts-plugin-trafficrouter-gatewayapi"
          }
        ]
        volumes = [
          {
            name     = "gateway-api-plugin"
            emptyDir = {}
          }
        ]
        volumeMounts = [
          {
            name      = "gateway-api-plugin"
            mountPath = "/plugins"
          }
        ]
      }
      dashboard = {
        enabled = true
      }
    })
  ]
}

resource "kubectl_manifest" "gateway_plugin_cluster_role" {
  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRole"
    metadata = {
      name = "argo-rollouts-gateway-api-plugin"
    }
    rules = [
      {
        apiGroups = [""]
        resources = ["services"]
        verbs     = ["get"]
      },
      {
        apiGroups = ["gateway.networking.k8s.io"]
        resources = ["httproutes"]
        verbs     = ["get", "list", "patch", "update"]
      },
    ]
  })
}

resource "kubectl_manifest" "gateway_plugin_cluster_role_binding" {
  yaml_body = yamlencode({
    apiVersion = "rbac.authorization.k8s.io/v1"
    kind       = "ClusterRoleBinding"
    metadata = {
      name = "argo-rollouts-gateway-api-plugin"
    }
    roleRef = {
      apiGroup = "rbac.authorization.k8s.io"
      kind     = "ClusterRole"
      name     = "argo-rollouts-gateway-api-plugin"
    }
    subjects = [
      {
        kind      = "ServiceAccount"
        name      = "argo-rollouts"
        namespace = "argo-rollouts"
      },
    ]
  })

  depends_on = [
    helm_release.argo_rollouts,
    kubectl_manifest.gateway_plugin_cluster_role,
  ]
}

resource "kubectl_manifest" "bootstrap" {
  count = var.enable_bootstrap ? 1 : 0

  yaml_body = yamlencode({
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "course-${var.environment}-bootstrap"
      namespace = "argocd"
      finalizers = [
        "resources-finalizer.argocd.argoproj.io",
      ]
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.gitops_repo_url
        targetRevision = var.gitops_target_revision
        path           = local.bootstrap_path
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = [
          "CreateNamespace=true",
          "ServerSideApply=true",
        ]
      }
    }
  })

  wait_for_rollout = false

  depends_on = [
    helm_release.argocd,
    helm_release.argo_rollouts,
    kubectl_manifest.gateway_plugin_cluster_role_binding,
  ]
}
