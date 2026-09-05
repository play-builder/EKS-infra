output "iam_role_arn" {
  description = "The ARN of the IAM role for the Cluster Autoscaler"
  value       = aws_iam_role.cluster_autoscaler.arn
}

output "iam_role_name" {
  description = "The name of the IAM role for the Cluster Autoscaler"
  value       = aws_iam_role.cluster_autoscaler.name
}

output "helm_release_name" {
  description = "Name of the Helm release"
  value       = helm_release.cluster_autoscaler.name
}

output "helm_release_status" {
  description = "Status of the Helm release"
  value       = helm_release.cluster_autoscaler.status
}
output "capacity_contract" {
  value = { mode = var.autoscaling_mode, capacity = var.autoscaler_capacity, image = "registry.k8s.io/autoscaling/cluster-autoscaler:v1.36.0@sha256:dc5d62770338c2902f31b01f95c9fc8c456fd88baa5364ca154d6e47069ec885", compatibility = "OVERRIDE_REQUIRES_CLOUD_RUNTIME" }
}
