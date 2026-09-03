output "release_name" {
  description = "Reloader Helm release name"
  value       = helm_release.this.name
}

output "namespace" {
  description = "Reloader controller namespace"
  value       = helm_release.this.namespace
}

output "chart_version" {
  description = "Pinned Reloader chart version"
  value       = var.chart_version
}
