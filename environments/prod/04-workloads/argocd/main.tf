data "aws_caller_identity" "current" {}

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
  course_ownership = {
    CourseId    = var.course_id
    AccountId   = data.aws_caller_identity.current.account_id
    Region      = var.aws_region
    Project     = var.project_name
    Environment = var.environment
    Layer       = "workloads"
    ManagedBy   = "Terraform"
  }
  bootstrap_path = var.bootstrap_path != "" ? var.bootstrap_path : "argocd/bootstrap/${var.environment}"
  rollouts_annotations = try(data.terraform_remote_state.platform.outputs.rollouts_amp_role_arn, null) != null ? {
    "eks.amazonaws.com/role-arn" = data.terraform_remote_state.platform.outputs.rollouts_amp_role_arn
  } : {}
  external_secret_health_lua = <<-LUA
    hs = {}
    hs.status = "Progressing"
    hs.message = "waiting for ExternalSecret Ready condition"
    if obj.metadata == nil or obj.metadata.deletionTimestamp ~= nil then return hs end
    if obj.status ~= nil and obj.status.conditions ~= nil then
      for _, condition in ipairs(obj.status.conditions) do
        if condition.type == "Ready" then
          local version = obj.status.syncedResourceVersion
          local generation = type(version) == "string" and string.match(version, "^(%d+)%-.+$") or nil
          if generation == nil or type(obj.status.refreshTime) ~= "string" or obj.status.refreshTime == "" then
            hs.status = "Progressing"
            hs.message = "waiting for ESO synced resource version and refresh time"
          elseif tonumber(generation) ~= obj.metadata.generation then
            hs.status = "Progressing"
            hs.message = "Ready condition is stale"
          elseif condition.status == "True" then
            if condition.reason == "SecretSynced" and condition.message == "secret synced" then
              hs.status = "Healthy"
              hs.message = condition.message
            end
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

resource "terraform_data" "course_ownership" {
  input = local.course_ownership
}

moved {
  from = helm_release.argocd
  to   = module.argocd.helm_release.argocd
}
module "argocd" {
  source            = "../../../../modules/addons/argocd-ha"
  name              = "${var.environment}-${var.project_name}"
  environment       = var.environment
  region            = var.aws_region
  platform          = var.argocd_platform
  tags              = merge(var.tags, local.course_ownership)
  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  oidc_provider     = data.terraform_remote_state.eks.outputs.oidc_provider
  health_customizations = {
    "course.health.external-secret.contract"                                = "external-secret-ready-health/v1"
    "resource.customizations.health.external-secrets.io_ExternalSecret"     = local.external_secret_health_lua
    "course.health.volume-snapshot.contract"                                = "volume-snapshot-ready-health/v1"
    "resource.customizations.health.snapshot.storage.k8s.io_VolumeSnapshot" = local.volume_snapshot_health_lua
  }
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
      }
      providerRBAC = {
        enabled   = true
        providers = { istio = true, smi = false, ambassador = false, awsLoadBalancerController = false, awsAppMesh = false, traefik = false, apisix = false, contour = false, glooPlatform = false, gatewayAPI = false }
      }
      dashboard = {
        enabled = true
      }
    })
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
        syncOptions = [
          "CreateNamespace=true",
          "ServerSideApply=true",
        ]
      }
    }
  })

  wait_for_rollout = false

  depends_on = [
    module.argocd,
    helm_release.argo_rollouts,
  ]
}
