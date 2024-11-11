# ============================================
# Metrics Server Module
# ============================================
# 용도: HPA/VPA 동작을 위한 필수 의존성
# kubectl top nodes/pods 명령어 지원
# 현업 필수: 모든 Production 클러스터에 설치 필요

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.chart_version
  namespace  = "kube-system"

  values = [
    yamlencode({
      # 리소스 제한 (OOM 방지)
      resources = {
        requests = {
          cpu    = "100m"
          memory = "200Mi"
        }
        limits = {
          cpu    = "100m"
          memory = "200Mi"
        }
      }

      # 메트릭 수집 간격 (기본 60초 → 15초로 더 빠른 스케일링)
      args = [
        "--metric-resolution=15s"
      ]
    })
  ]
}