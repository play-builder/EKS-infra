resource "helm_release" "this" {
  name             = var.release_name
  repository       = "https://stakater.github.io/stakater-charts"
  chart            = "reloader"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true
  atomic           = true
  timeout          = 600

  values = [
    yamlencode({
      reloader = {
        reloadStrategy = "annotations"
        isArgoRollouts = true
        watchGlobally  = true
      }
    })
  ]
}
