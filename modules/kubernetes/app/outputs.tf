# =============================================================================
# Kubernetes App 모듈 - Outputs
# =============================================================================
# 실무 관점: 다른 모듈(Ingress 등)에서 참조할 정보 제공
# =============================================================================

# -----------------------------------------------------------------------------
# Namespace 출력
# -----------------------------------------------------------------------------
output "namespace" {
  description = "앱이 배포된 네임스페이스"
  value       = local.namespace
}

# -----------------------------------------------------------------------------
# Deployment 출력
# -----------------------------------------------------------------------------
output "deployment_name" {
  description = "Deployment 이름"
  value       = kubernetes_deployment_v1.this.metadata[0].name
}

output "deployment_labels" {
  description = "Deployment 레이블"
  value       = kubernetes_deployment_v1.this.metadata[0].labels
}

output "selector_labels" {
  description = "Pod selector 레이블 (Service 연결용)"
  value       = local.selector_labels
}

# -----------------------------------------------------------------------------
# Service 출력
# -----------------------------------------------------------------------------
output "service_name" {
  description = "Service 이름"
  value       = var.create_service ? kubernetes_service_v1.this[0].metadata[0].name : null
}

output "service_port" {
  description = "Service 포트"
  value       = var.create_service ? var.service_port : null
}

output "service_type" {
  description = "Service 타입"
  value       = var.create_service ? var.service_type : null
}

# Cluster 내부 DNS
output "service_dns" {
  description = "Service DNS 이름 (클러스터 내부)"
  value       = var.create_service ? "${kubernetes_service_v1.this[0].metadata[0].name}.${local.namespace}.svc.cluster.local" : null
}

# -----------------------------------------------------------------------------
# 앱 정보 요약 (Ingress 모듈에서 활용)
# -----------------------------------------------------------------------------
output "app_info" {
  description = "앱 정보 요약 (Ingress 연동용)"
  value = {
    name              = var.app_name
    namespace         = local.namespace
    service_name      = var.create_service ? kubernetes_service_v1.this[0].metadata[0].name : null
    service_port      = var.service_port
    health_check_path = var.health_check_path
  }
}