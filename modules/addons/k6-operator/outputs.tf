output "enabled" {
  description = "Whether the Ch16 k6 operator is installed"
  value       = var.enable_k6_operator
}

output "namespace" {
  description = "Dedicated k6 operator namespace"
  value       = var.enable_k6_operator ? helm_release.this[0].namespace : null
}

output "chart_version" {
  description = "Pinned k6 operator chart version"
  value       = var.enable_k6_operator ? var.chart_version : null
}
