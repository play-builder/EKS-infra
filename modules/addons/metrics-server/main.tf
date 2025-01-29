resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.chart_version
  namespace  = "kube-system"

  values = [
    yamlencode({
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

      args = [
        "--metric-resolution=15s"
      ]
    })
  ]
}
