output "iam_role_arn" {
  description = "IAM Role ARN for ADOT Collector"
  value       = aws_iam_role.adot.arn
}

output "addon_version" {
  description = "ADOT EKS addon version"
  value       = aws_eks_addon.adot.addon_version
}