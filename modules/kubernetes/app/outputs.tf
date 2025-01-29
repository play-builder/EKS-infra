output "namespace" {
  description = "Namespace where the app is deployed"
  value       = local.namespace
}

output "deployment_name" {
  description = "Deployment name"
  value       = kubernetes_deployment_v1.this.metadata[0].name
}

output "deployment_labels" {
  description = "Deployment labels"
  value       = kubernetes_deployment_v1.this.metadata[0].labels
}

output "selector_labels" {
  description = "Pod selector labels (for Service connection)"
  value       = local.selector_labels
}

output "service_name" {
  description = "Service name"
  value       = var.create_service ? kubernetes_service_v1.this[0].metadata[0].name : null
}

output "service_port" {
  description = "Service port"
  value       = var.create_service ? var.service_port : null
}

output "service_type" {
  description = "Service type"
  value       = var.create_service ? var.service_type : null
}

output "service_dns" {
  description = "Service DNS name (internal to cluster)"
  value       = var.create_service ? "${kubernetes_service_v1.this[0].metadata[0].name}.${local.namespace}.svc.cluster.local" : null
}

output "app_info" {
  description = "App info summary (for Ingress integration)"
  value = {
    name              = var.app_name
    namespace         = local.namespace
    service_name      = var.create_service ? kubernetes_service_v1.this[0].metadata[0].name : null
    service_port      = var.service_port
    health_check_path = var.health_check_path
  }
}
