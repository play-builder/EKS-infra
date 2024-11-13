output "helm_release_name" {
  description = "Name of the Helm release"
  value       = helm_release.metrics_server.name
}

output "helm_release_status" {
  description = "Status of the Helm release"
  value       = helm_release.metrics_server.status
}