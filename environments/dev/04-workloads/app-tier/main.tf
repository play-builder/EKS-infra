data "terraform_remote_state" "eks" {
  backend = "s3"

  config = {
    bucket = "plydevops-infra-tf-dev"
    key    = "dev/02-eks/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "platform" {
  backend = "s3"

  config = {
    bucket = "plydevops-infra-tf-dev"
    key    = "dev/03-platform/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  name = "${var.environment}-${var.project_name}"

  common_tags = merge(var.tags, {
    Environment = var.environment
    Project     = var.project_name
    Application = "online-boutique"
    ManagedBy   = "terraform"
  })

  acm_certificate_arn = data.terraform_remote_state.platform.outputs.acm_certificate_arn

  ingress_host = var.ingress_hostname != "" ? var.ingress_hostname : "shop.playdevops.click"
}

resource "kubernetes_namespace_v1" "online_boutique" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name = var.namespace

    labels = {
      name        = var.namespace
      environment = var.environment
      app         = "online-boutique"
    }
  }
}

resource "helm_release" "online_boutique" {
  name       = var.helm_release_name
  repository = "oci://us-docker.pkg.dev/online-boutique-ci/charts"
  chart      = "onlineboutique"
  version    = var.helm_chart_version
  namespace  = var.namespace

  depends_on = [kubernetes_namespace_v1.online_boutique]

  timeout = 600
  wait    = true

  values = [
    yamlencode({
      frontend = {
        service = {
          type = var.enable_ingress ? "ClusterIP" : "LoadBalancer"
        }

        resources = {
          requests = {
            cpu    = "100m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "200m"
            memory = "128Mi"
          }
        }
      }

      loadGenerator = {
        enabled = var.enable_load_generator
        resources = {
          requests = {
            cpu    = "100m"
            memory = "128Mi"
          }
          limits = {
            cpu    = "200m"
            memory = "256Mi"
          }
        }
      }

      cartservice = {
        resources = {
          requests = {
            cpu    = "100m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "200m"
            memory = "128Mi"
          }
        }
      }

      redis = {
        resources = {
          requests = {
            cpu    = "50m"
            memory = "64Mi"
          }
          limits = {
            cpu    = "100m"
            memory = "128Mi"
          }
        }
      }

      networkPolicies = {
        enabled = var.enable_network_policies
      }

      serviceAccounts = {
        create = true
      }
    })
  ]
}

resource "kubernetes_ingress_v1" "online_boutique" {
  count = var.enable_ingress ? 1 : 0

  depends_on = [helm_release.online_boutique]

  metadata {
    name      = "${var.helm_release_name}-ingress"
    namespace = var.namespace

    annotations = {
      "kubernetes.io/ingress.class"                    = var.ingress_class_name
      "alb.ingress.kubernetes.io/scheme"               = var.alb_scheme
      "alb.ingress.kubernetes.io/target-type"          = "ip"
      "alb.ingress.kubernetes.io/healthcheck-path"     = "/"
      "alb.ingress.kubernetes.io/healthcheck-protocol" = "HTTP"

      "alb.ingress.kubernetes.io/listen-ports"    = "[{\"HTTP\": 80}, {\"HTTPS\": 443}]"
      "alb.ingress.kubernetes.io/ssl-redirect"    = "443"
      "alb.ingress.kubernetes.io/certificate-arn" = local.acm_certificate_arn

      "alb.ingress.kubernetes.io/group.name"  = var.ingress_group_name
      "alb.ingress.kubernetes.io/group.order" = "100"

      "alb.ingress.kubernetes.io/load-balancer-name" = "${local.name}-online-boutique"

      "external-dns.alpha.kubernetes.io/hostname" = local.ingress_host
    }

    labels = local.common_tags
  }

  spec {
    ingress_class_name = var.ingress_class_name

    rule {
      host = local.ingress_host

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = "frontend"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "frontend" {
  count = var.enable_hpa ? 1 : 0

  depends_on = [helm_release.online_boutique]

  metadata {
    name      = "frontend-hpa"
    namespace = var.namespace
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = "frontend"
    }

    min_replicas = var.hpa_min_replicas
    max_replicas = var.hpa_max_replicas

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = var.hpa_target_cpu
        }
      }
    }

    behavior {
      scale_down {
        stabilization_window_seconds = 300
        select_policy                = "Min"
        policy {
          type           = "Percent"
          value          = 10
          period_seconds = 60
        }
      }
      scale_up {
        stabilization_window_seconds = 0
        select_policy                = "Max"
        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 15
        }
        policy {
          type           = "Pods"
          value          = 4
          period_seconds = 15
        }
      }
    }
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "checkoutservice" {
  count = var.enable_hpa ? 1 : 0

  depends_on = [helm_release.online_boutique]

  metadata {
    name      = "checkoutservice-hpa"
    namespace = var.namespace
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = "checkoutservice"
    }

    min_replicas = var.hpa_min_replicas
    max_replicas = var.hpa_max_replicas

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = var.hpa_target_cpu
        }
      }
    }
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "cartservice" {
  count = var.enable_hpa ? 1 : 0

  depends_on = [helm_release.online_boutique]

  metadata {
    name      = "cartservice-hpa"
    namespace = var.namespace
  }

  spec {
    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = "cartservice"
    }

    min_replicas = var.hpa_min_replicas
    max_replicas = var.hpa_max_replicas

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = var.hpa_target_cpu
        }
      }
    }
  }
}

