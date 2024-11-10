# ============================================
# EBS CSI Driver Add-on Module Outputs
# ============================================

# ============================================
# IAM Outputs
# ============================================
output "iam_role_arn" {
  description = "ARN of the IAM role for EBS CSI Driver"
  value       = aws_iam_role.ebs_csi.arn
}

output "iam_role_name" {
  description = "Name of the IAM role"
  value       = aws_iam_role.ebs_csi.name
}

output "iam_policy_arn" {
  description = "ARN of the IAM policy (if custom policy is used)"
  value       = var.use_aws_managed_policy ? var.aws_managed_policy_arn : aws_iam_policy.ebs_csi[0].arn
}

# ============================================
# EKS Add-on Outputs
# ============================================
output "addon_id" {
  description = "EKS Add-on ID"
  value       = aws_eks_addon.ebs_csi.id
}

output "addon_arn" {
  description = "ARN of the EKS Add-on"
  value       = aws_eks_addon.ebs_csi.arn
}

output "addon_version" {
  description = "Version of the EBS CSI Driver add-on"
  value       = aws_eks_addon.ebs_csi.addon_version
}



# ============================================
# Service Account Outputs
# ============================================
output "service_account_name" {
  description = "Name of the Kubernetes Service Account"
  value       = var.service_account_name
}

output "service_account_namespace" {
  description = "Namespace of the Service Account"
  value       = var.namespace
}