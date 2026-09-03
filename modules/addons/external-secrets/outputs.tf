output "release_name" {
  description = "Terraform-owned External Secrets Helm release"
  value       = helm_release.this.name
}

output "namespace" {
  description = "External Secrets controller namespace"
  value       = helm_release.this.namespace
}

output "chart_version" {
  description = "Pinned External Secrets chart version"
  value       = var.chart_version
}

output "status" {
  description = "Helm release status"
  value       = helm_release.this.status
}
