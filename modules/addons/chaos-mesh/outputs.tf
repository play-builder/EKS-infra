output "enabled" {
  description = "Whether Chaos Mesh is enabled for this environment"
  value       = var.enable_chaos_mesh
}

output "namespace" {
  description = "Chaos Mesh control-plane namespace"
  value       = var.enable_chaos_mesh ? var.namespace : null
}

output "chart_version" {
  description = "Pinned Chaos Mesh chart version"
  value       = var.enable_chaos_mesh ? var.chart_version : null
}

output "game_day_contract" {
  description = "Bounded fault admission settings"
  value = {
    courseId                   = var.course_id
    allowedNamespaces          = var.allowed_namespaces
    maxFaultDurationSeconds    = var.max_fault_duration_seconds
    maxFaults                  = var.max_faults
    controllerCloudWaitSeconds = var.controller_cloud_wait_seconds
    costBoundary               = "existing-eks-compute"
  }
}
