locals {
  common_labels = {
    "app.kubernetes.io/managed-by" = "terraform"
    "environment"                  = var.environment
    "module"                       = "alb-ssl-ingress"
  }

  certificate_arn = var.acm_certificate_arn

  default_backend = one([for svc in var.backend_services : svc if svc.is_default])

  path_backends = [for svc in var.backend_services : svc if !svc.is_default]
}

resource "kubernetes_ingress_v1" "this" {
  metadata {
    name      = var.ingress_name
    namespace = var.namespace
    labels    = local.common_labels

    annotations = merge({
      "alb.ingress.kubernetes.io/load-balancer-name" = var.load_balancer_name
      "alb.ingress.kubernetes.io/scheme"             = var.alb_scheme

      "alb.ingress.kubernetes.io/healthcheck-protocol"         = var.health_check.protocol
      "alb.ingress.kubernetes.io/healthcheck-port"             = var.health_check.port
      "alb.ingress.kubernetes.io/healthcheck-interval-seconds" = var.health_check.interval_seconds
      "alb.ingress.kubernetes.io/healthcheck-timeout-seconds"  = var.health_check.timeout_seconds
      "alb.ingress.kubernetes.io/success-codes"                = var.health_check.success_codes
      "alb.ingress.kubernetes.io/healthy-threshold-count"      = var.health_check.healthy_threshold
      "alb.ingress.kubernetes.io/unhealthy-threshold-count"    = var.health_check.unhealthy_threshold

      "alb.ingress.kubernetes.io/listen-ports" = jsonencode([
        { "HTTPS" = 443 },
        { "HTTP" = 80 }
      ])
      "alb.ingress.kubernetes.io/certificate-arn" = local.certificate_arn
      "alb.ingress.kubernetes.io/ssl-policy"      = var.ssl_policy

      "alb.ingress.kubernetes.io/ssl-redirect" = var.ssl_redirect_enabled ? "443" : ""

      "external-dns.alpha.kubernetes.io/hostname" = length(var.ingress_hostnames) > 0 ? join(",", var.ingress_hostnames) : null
      },
      var.additional_annotations
    )
  }

  spec {
    ingress_class_name = var.ingress_class_name

    dynamic "default_backend" {
      for_each = local.default_backend != null ? [local.default_backend] : []
      iterator = db
      content {
        service {
          name = db.value.name
          port {
            number = db.value.port
          }
        }
      }
    }

    dynamic "rule" {
      for_each = (length(var.ingress_hostnames) > 0 && length(local.path_backends) > 0) ? var.ingress_hostnames : []
      content {
        host = rule.value
        http {
          dynamic "path" {
            for_each = local.path_backends
            iterator = backend_path
            content {
              path      = backend_path.value.path
              path_type = backend_path.value.path_type
              backend {
                service {
                  name = backend_path.value.name
                  port { number = backend_path.value.port }
                }
              }
            }
          }
        }
      }
    }
  }
}
