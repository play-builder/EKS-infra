locals {
  name_prefix = var.app_name

  common_labels = merge({
    "app.kubernetes.io/name"       = var.app_name
    "app.kubernetes.io/instance"   = "${var.app_name}-${var.environment}"
    "app.kubernetes.io/managed-by" = "terraform"
    "environment"                  = var.environment
  }, var.labels)

  selector_labels = {
    "app" = var.app_name
  }

  namespace = var.create_namespace ? kubernetes_namespace_v1.this[0].metadata[0].name : var.namespace
}

resource "kubernetes_namespace_v1" "this" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name   = var.namespace
    labels = local.common_labels
  }
}

resource "kubernetes_deployment_v1" "this" {
  metadata {
    name        = "${local.name_prefix}-deployment"
    namespace   = local.namespace
    labels      = local.common_labels
    annotations = var.annotations
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = local.selector_labels
    }

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = var.rolling_update.max_surge
        max_unavailable = var.rolling_update.max_unavailable
      }
    }

    template {
      metadata {
        labels      = merge(local.common_labels, local.selector_labels)
        annotations = var.pod_annotations
      }

      spec {
        service_account_name = var.service_account_name

        container {
          name              = var.app_name
          image             = var.container_image
          image_pull_policy = var.image_pull_policy

          port {
            container_port = var.container_port
            protocol       = "TCP"
          }

          resources {
            requests = {
              cpu    = var.resources.requests.cpu
              memory = var.resources.requests.memory
            }
            limits = {
              cpu    = var.resources.limits.cpu
              memory = var.resources.limits.memory
            }
          }

          dynamic "env" {
            for_each = var.env_vars
            content {
              name  = env.key
              value = env.value
            }
          }

          dynamic "env_from" {
            for_each = var.env_from_secrets
            content {
              secret_ref {
                name     = env_from.value.secret_name
                optional = env_from.value.optional
              }
            }
          }

          dynamic "env_from" {
            for_each = var.env_from_configmaps
            content {
              config_map_ref {
                name     = env_from.value.configmap_name
                optional = env_from.value.optional
              }
            }
          }

          dynamic "liveness_probe" {
            for_each = var.liveness_probe.enabled ? [1] : []
            content {
              http_get {
                path = var.health_check_path
                port = var.container_port
              }
              initial_delay_seconds = var.liveness_probe.initial_delay_seconds
              period_seconds        = var.liveness_probe.period_seconds
              timeout_seconds       = var.liveness_probe.timeout_seconds
              failure_threshold     = var.liveness_probe.failure_threshold
            }
          }

          dynamic "readiness_probe" {
            for_each = var.readiness_probe.enabled ? [1] : []
            content {
              http_get {
                path = var.health_check_path
                port = var.container_port
              }
              initial_delay_seconds = var.readiness_probe.initial_delay_seconds
              period_seconds        = var.readiness_probe.period_seconds
              timeout_seconds       = var.readiness_probe.timeout_seconds
              failure_threshold     = var.readiness_probe.failure_threshold
            }
          }

          dynamic "volume_mount" {
            for_each = var.volumes
            content {
              name       = volume_mount.value.name
              mount_path = volume_mount.value.mount_path
              read_only  = volume_mount.value.read_only
            }
          }
        }

        dynamic "volume" {
          for_each = var.volumes
          content {
            name = volume.value.name

            dynamic "empty_dir" {
              for_each = volume.value.type == "emptyDir" ? [1] : []
              content {}
            }

            dynamic "config_map" {
              for_each = volume.value.type == "configMap" ? [1] : []
              content {
                name = volume.value.source
              }
            }

            dynamic "secret" {
              for_each = volume.value.type == "secret" ? [1] : []
              content {
                secret_name = volume.value.source
              }
            }

            dynamic "persistent_volume_claim" {
              for_each = volume.value.type == "pvc" ? [1] : []
              content {
                claim_name = volume.value.source
              }
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"]
    ]
  }
}

resource "kubernetes_service_v1" "this" {
  count = var.create_service ? 1 : 0

  metadata {
    name        = "${local.name_prefix}-service"
    namespace   = local.namespace
    labels      = local.common_labels
    annotations = var.service_annotations
  }

  spec {
    selector = local.selector_labels

    port {
      name        = "http"
      port        = var.service_port
      target_port = var.container_port
      protocol    = "TCP"

      node_port = var.service_type == "NodePort" ? var.node_port : null
    }

    type = var.service_type
  }

  depends_on = [kubernetes_deployment_v1.this]
}
