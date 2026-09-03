resource "helm_release" "this" {
  name             = var.release_name
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true
  atomic           = true
  timeout          = 900

  values = [
    yamlencode({
      installCRDs = true
      webhook = {
        create = true
      }
      certController = {
        create = true
      }
    })
  ]
}
