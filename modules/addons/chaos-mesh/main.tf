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
      # Keep the dashboard off: Ch25 uses the API and must not add an
      # unbounded user-facing service to the existing EKS cluster.
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
          name      = "chaos-mesh-course-contract"
          namespace = var.namespace
        }
        data = {
          courseId                = var.course_id
          allowedNamespaces       = join(",", var.allowed_namespaces)
          maxFaultDurationSeconds = tostring(var.max_fault_duration_seconds)
          maxFaults               = tostring(var.max_faults)
          costBoundary            = "existing-eks-compute"
        }
      }]
      course = {
        schemaVersion              = "course.chaos-mesh/v1"
        courseId                   = var.course_id
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
