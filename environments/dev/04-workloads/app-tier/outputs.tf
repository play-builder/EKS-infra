output "namespace" {
  description = "Kubernetes namespace where Online Boutique is deployed"
  value       = var.namespace
}

output "helm_release_name" {
  description = "Helm release name"
  value       = helm_release.online_boutique.name
}

output "helm_release_status" {
  description = "Helm release status"
  value       = helm_release.online_boutique.status
}

output "helm_release_version" {
  description = "Helm chart version"
  value       = helm_release.online_boutique.version
}

output "application_url" {
  description = "URL to access Online Boutique"
  value       = var.enable_ingress ? "https://${local.ingress_host}" : "Use kubectl port-forward"
}

output "ingress_hostname" {
  description = "Ingress hostname"
  value       = var.enable_ingress ? local.ingress_host : null
}

output "hpa_enabled" {
  description = "Whether HPA is enabled"
  value       = var.enable_hpa
}

output "hpa_frontend" {
  description = "Frontend HPA name"
  value       = var.enable_hpa ? kubernetes_horizontal_pod_autoscaler_v2.frontend[0].metadata[0].name : null
}

output "summary" {
  description = "Deployment summary"
  value = {
    environment     = var.environment
    namespace       = var.namespace
    helm_release    = helm_release.online_boutique.name
    chart_version   = var.helm_chart_version
    load_generator  = var.enable_load_generator
    ingress_enabled = var.enable_ingress
    hpa_enabled     = var.enable_hpa
    url             = var.enable_ingress ? "https://${local.ingress_host}" : "kubectl port-forward svc/frontend 8080:80 -n ${var.namespace}"
  }
}

