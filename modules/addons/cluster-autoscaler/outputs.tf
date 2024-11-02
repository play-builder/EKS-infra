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