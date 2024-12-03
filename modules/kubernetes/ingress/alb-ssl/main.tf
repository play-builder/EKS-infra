# =============================================================================
# ALB SSL Ingress 모듈 - Main
# =============================================================================
# 실무 관점: ACM 인증서 + ALB Ingress 생성
# 
# 역할:
#   - ACM 인증서 생성/관리
#   - ALB Ingress 설정 (SSL 종료, 경로 기반 라우팅)
#   - 외부 앱 모듈의 Service들을 백엔드로 연결
#
# 주의: Deployment/Service는 이 모듈에서 생성하지 않음!
#       → app 모듈에서 생성한 Service를 backend_services로 전달받음
# =============================================================================

locals {
  # 공통 레이블
  common_labels = {
    "app.kubernetes.io/managed-by" = "terraform"
    "environment"                  = var.environment
    "module"                       = "alb-ssl-ingress"
  }

  # 인증서 ARN 결정 (신규 생성 vs 기존 사용)
  certificate_arn = var.acm_certificate_arn

  # 기본 백엔드 찾기
  default_backend = one([for svc in var.backend_services : svc if svc.is_default])

  # 경로 기반 라우팅 서비스 (기본 백엔드 제외)
  path_backends = [for svc in var.backend_services : svc if !svc.is_default]
}



# =============================================================================
# Kubernetes Ingress (ALB)
# =============================================================================
# 실무: AWS Load Balancer Controller가 이 Ingress를 보고 ALB 생성
#
# 트래픽 흐름:
#   Client → ALB(443) → SSL 종료 → Service(80) → Pod
#                ↓
#         HTTP(80) → 443 리다이렉트

resource "kubernetes_ingress_v1" "this" {
  metadata {
    name      = var.ingress_name
    namespace = var.namespace
    labels    = local.common_labels

    annotations = merge({
      # =========== ALB 기본 설정 ===========
      "alb.ingress.kubernetes.io/load-balancer-name" = var.load_balancer_name
      "alb.ingress.kubernetes.io/scheme"             = var.alb_scheme

      # =========== Health Check 설정 ===========
      "alb.ingress.kubernetes.io/healthcheck-protocol"         = var.health_check.protocol
      "alb.ingress.kubernetes.io/healthcheck-port"             = var.health_check.port
      "alb.ingress.kubernetes.io/healthcheck-interval-seconds" = var.health_check.interval_seconds
      "alb.ingress.kubernetes.io/healthcheck-timeout-seconds"  = var.health_check.timeout_seconds
      "alb.ingress.kubernetes.io/success-codes"                = var.health_check.success_codes
      "alb.ingress.kubernetes.io/healthy-threshold-count"      = var.health_check.healthy_threshold
      "alb.ingress.kubernetes.io/unhealthy-threshold-count"    = var.health_check.unhealthy_threshold


      # =========== SSL/TLS 설정 ===========
      "alb.ingress.kubernetes.io/listen-ports" = jsonencode([
        { "HTTPS" = 443 },
        { "HTTP" = 80 }
      ])
      "alb.ingress.kubernetes.io/certificate-arn" = local.certificate_arn
      "alb.ingress.kubernetes.io/ssl-policy"      = var.ssl_policy

      # =========== SSL 리다이렉트 ===========
      "alb.ingress.kubernetes.io/ssl-redirect" = var.ssl_redirect_enabled ? "443" : ""

      # ▼▼▼ [추가] ExternalDNS가 이 줄을 보고 Route53을 업데이트합니다! ▼▼▼
      "external-dns.alpha.kubernetes.io/hostname" = length(var.ingress_hostnames) > 0 ? join(",", var.ingress_hostnames) : null


      },
      # [추가 설정 병합] 외부에서 주입된 group.name, group.order 등이 여기서 합쳐짐
      var.additional_annotations
    )
  }

  spec {
    ingress_class_name = var.ingress_class_name

    # =========== 기본 백엔드 ===========
    # 매칭되는 경로가 없을 때 라우팅
    dynamic "default_backend" {
      for_each = local.default_backend != null ? [local.default_backend] : []
      iterator = db # 반복자 이름을 'db'로 명시
      content {
        service {
          name = db.value.name
          port {
            number = db.value.port
          }
        }
      }
    }

    # =========== 경로 기반 라우팅 ===========
    dynamic "rule" {
      for_each = (length(var.ingress_hostnames) > 0 && length(local.path_backends) > 0) ? var.ingress_hostnames : []
      content {
        host = rule.value # 리스트의 도메인 이름 (없으면 null)
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