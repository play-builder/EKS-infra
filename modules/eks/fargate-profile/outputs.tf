output "profile_arn" {
  description = "The ARN of the Fargate Profile"
  value       = aws_eks_fargate_profile.fargate.arn
}

output "role_arn" {
  description = "The ARN of the Pod Execution Role"
  value       = aws_iam_role.fargate_pod_execution.arn
}