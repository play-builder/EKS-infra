output "argocd_release" {
  description = "Argo CD Helm release name"
  value       = helm_release.argocd.name
}

output "course_ownership" {
  description = "Canonical CourseId ownership metadata for this untaggable workload root"
  value       = terraform_data.course_ownership.input
}

output "argo_rollouts_release" {
  description = "Argo Rollouts Helm release name"
  value       = helm_release.argo_rollouts.name
}

output "bootstrap_application" {
  description = "Root Application name, or null when bootstrap is deliberately disabled"
  value       = var.enable_bootstrap ? "course-${var.environment}-bootstrap" : null
}

output "verification_commands" {
  description = "Commands that prove the controllers and bootstrap state"
  value       = <<-EOT
    kubectl -n argocd get pods
    kubectl -n argo-rollouts get pods
    kubectl -n argo-rollouts get sa argo-rollouts -o jsonpath='{.metadata.annotations.eks\\.amazonaws\\.com/role-arn}'
    kubectl -n argocd get application course-${var.environment}-bootstrap
  EOT
}
