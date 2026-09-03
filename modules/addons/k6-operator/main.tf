resource "helm_release" "this" {
  count = var.enable_k6_operator ? 1 : 0

  name             = "k6-operator"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "k6-operator"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true
  atomic           = true
  timeout          = 600

  values = [
    yamlencode({
      installCRDs = true
      namespace = {
        create = true
      }
      metrics = {
        serviceMonitor = {
          enabled = false
        }
      }
    })
  ]
}
