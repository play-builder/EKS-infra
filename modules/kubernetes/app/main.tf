

# ===== Namespace =====
# =============================================================================
# Kubernetes App 모듈 - Main
# =============================================================================
# 실무 관점: Stateless 애플리케이션의 표준 배포 패턴
# 
# 구성요소:
#   1. Namespace (선택적)
#   2. Deployment (Pod 관리)
#   3. Service (네트워크 노출)
#
# 사용 시나리오:
#   - 웹 애플리케이션 배포
#   - API 서버 배포
#   - 마이크로서비스 배포
# =============================================================================

locals {
  # 리소스 이름 생성
  name_prefix = var.app_name

  # 공통 레이블 (Kubernetes 권장 레이블 포함)
  common_labels = merge({
    "app.kubernetes.io/name"       = var.app_name
    "app.kubernetes.io/instance"   = "${var.app_name}-${var.environment}"
    "app.kubernetes.io/managed-by" = "terraform"
    "environment"                  = var.environment
  }, var.labels)

  # Selector 레이블 (변경 불가능하므로 최소한으로)
  selector_labels = {
    "app" = var.app_name
  }

  # 네임스페이스 결정
  namespace = var.create_namespace ? kubernetes_namespace_v1.this[0].metadata[0].name : var.namespace
}

# =============================================================================
# Namespace (선택적)
# =============================================================================
# 실무: 환경/팀/프로젝트별 네임스페이스 분리 권장
# 왜: 리소스 격리, RBAC 적용, 리소스 쿼터 적용 용이

resource "kubernetes_namespace_v1" "this" {
  count = var.create_namespace ? 1 : 0

  metadata {
    name   = var.namespace
    labels = local.common_labels
  }
}

# =============================================================================
# Deployment
# =============================================================================
# 실무: Stateless 애플리케이션의 핵심 리소스
# 왜 Deployment:
#   - 롤링 업데이트 지원
#   - 자동 복구 (Pod 재생성)
#   - 스케일링 용이
#   - 버전 롤백 가능

resource "kubernetes_deployment_v1" "this" {
  metadata {
    name        = "${local.name_prefix}-deployment"
    namespace   = local.namespace
    labels      = local.common_labels
    annotations = var.annotations
  }

  spec {
    replicas = var.replicas

    # Selector는 변경 불가능 - 신중하게 설정
    selector {
      match_labels = local.selector_labels
    }

    # Rolling Update 전략
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
        # ServiceAccount 설정 (IRSA 등에 필요)

        service_account_name = var.service_account_name

        # 메인 컨테이너
        container {
          name              = var.app_name
          image             = var.container_image
          image_pull_policy = var.image_pull_policy

          # 포트 설정
          port {
            container_port = var.container_port
            protocol       = "TCP"
          }

          # 리소스 제한 (프로덕션 필수!)
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

          # 환경 변수 - 직접 정의
          dynamic "env" {
            for_each = var.env_vars
            content {
              name  = env.key
              value = env.value
            }
          }

          # 환경 변수 - Secret에서 로드
          dynamic "env_from" {
            for_each = var.env_from_secrets
            content {
              secret_ref {
                name     = env_from.value.secret_name
                optional = env_from.value.optional
              }
            }
          }

          # 환경 변수 - ConfigMap에서 로드
          dynamic "env_from" {
            for_each = var.env_from_configmaps
            content {
              config_map_ref {
                name     = env_from.value.configmap_name
                optional = env_from.value.optional
              }
            }
          }

          # Liveness Probe - Pod 재시작 트리거
          # 실무: 애플리케이션이 응답 불가 상태일 때 자동 재시작
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

          # Readiness Probe - 트래픽 수신 여부 결정
          # 실무: Pod가 준비될 때까지 Service 엔드포인트에서 제외
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

          # 볼륨 마운트
          dynamic "volume_mount" {
            for_each = var.volumes
            content {
              name       = volume_mount.value.name
              mount_path = volume_mount.value.mount_path
              read_only  = volume_mount.value.read_only
            }
          }
        }

        # 볼륨 정의
        dynamic "volume" {
          for_each = var.volumes
          content {
            name = volume.value.name

            # EmptyDir 볼륨
            dynamic "empty_dir" {
              for_each = volume.value.type == "emptyDir" ? [1] : []
              content {}
            }

            # ConfigMap 볼륨
            dynamic "config_map" {
              for_each = volume.value.type == "configMap" ? [1] : []
              content {
                name = volume.value.source
              }
            }

            # Secret 볼륨
            dynamic "secret" {
              for_each = volume.value.type == "secret" ? [1] : []
              content {
                secret_name = volume.value.source
              }
            }

            # PVC 볼륨
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

  # 외부 변경 무시 (kubectl rollout restart 등)
  lifecycle {
    ignore_changes = [
      spec[0].template[0].metadata[0].annotations["kubectl.kubernetes.io/restartedAt"]
    ]
  }
}

# =============================================================================
# Service
# =============================================================================
# 실무: Pod들에 대한 네트워크 접근점 제공
# 왜 Service:
#   - Pod IP는 변경됨 → Service는 고정 엔드포인트 제공
#   - 로드밸런싱 (여러 Pod에 트래픽 분산)
#   - 서비스 디스커버리 (DNS: <service>.<namespace>.svc.cluster.local)

resource "kubernetes_service_v1" "this" {
  count = var.create_service ? 1 : 0

  metadata {
    name        = "${local.name_prefix}-service"
    namespace   = local.namespace
    labels      = local.common_labels
    annotations = var.service_annotations
  }

  spec {
    # Deployment의 Pod를 선택
    selector = local.selector_labels

    port {
      name        = "http"
      port        = var.service_port
      target_port = var.container_port
      protocol    = "TCP"

      # NodePort 지정 (선택적)
      node_port = var.service_type == "NodePort" ? var.node_port : null
    }

    type = var.service_type
  }

  depends_on = [kubernetes_deployment_v1.this]
}