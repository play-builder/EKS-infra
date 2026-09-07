resource "helm_release" "this" {
  count = var.enable_chaos_mesh ? 1 : 0

  name             = "chaos-mesh"
  repository       = "https://charts.chaos-mesh.org"
  chart            = "chaos-mesh"
  version          = var.chart_version
  namespace        = var.namespace
  create_namespace = true
  atomic           = true
  wait             = true
  timeout          = var.controller_cloud_wait_seconds

  values = [
    yamlencode({
      # Disable the dashboard to avoid exposing an additional user-facing service.
      dashboard = {
        create = false
      }
      controllerManager = {
        enableFilterNamespace = true
        targetNamespace       = var.allowed_namespaces[0]
      }
      chaosDaemon = {
        enabled = true
      }
      extraObjects = [{
        apiVersion = "v1"
        kind       = "ConfigMap"
        metadata = {
          name      = "chaos-mesh-fault-contract"
          namespace = var.namespace
        }
        data = {
          allowedNamespaces       = join(",", var.allowed_namespaces)
          maxFaultDurationSeconds = tostring(var.max_fault_duration_seconds)
          maxFaults               = tostring(var.max_faults)
          costBoundary            = "existing-eks-compute"
        }
      }]
      contract = {
        schemaVersion              = "playbuilder.chaos-mesh/v1"
        environment                = var.environment
        allowedNamespaces          = var.allowed_namespaces
        maxFaultDurationSeconds    = var.max_fault_duration_seconds
        maxFaults                  = var.max_faults
        controllerCloudWaitSeconds = var.controller_cloud_wait_seconds
        costBoundary               = "existing-eks-compute"
      }
    })
  ]
}
