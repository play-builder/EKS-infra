
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
    hpa_min         = var.hpa_min_replicas
    hpa_max         = var.hpa_max_replicas
    url             = var.enable_ingress ? "https://${local.ingress_host}" : "kubectl port-forward svc/frontend 8080:80 -n ${var.namespace}"
  }
}

output "verification_commands" {
  description = "Commands to verify the deployment"
  value       = <<-EOT
    # ============================================
    # Verify Online Boutique Deployment
    # ============================================
    
    # 1. Check all pods
    kubectl -n ${var.namespace} get pods
    
    # 2. Check services
    kubectl -n ${var.namespace} get svc
    
    # 3. Check HPA
    kubectl -n ${var.namespace} get hpa
    
    # 4. Check Ingress
    kubectl -n ${var.namespace} get ingress
    
    # 5. Check ALB
    kubectl -n ${var.namespace} describe ingress ${var.helm_release_name}-ingress
    
    # 6. Test Application (after DNS propagation)
    curl -I https://${local.ingress_host}
    
    # 7. Port-forward for local testing
    kubectl -n ${var.namespace} port-forward svc/frontend 8080:80
  EOT
}
