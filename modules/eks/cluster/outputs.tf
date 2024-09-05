# ============================================
# EKS Cluster Module - Outputs
# ============================================
# 리팩토링: Node Group outputs 모두 제거, Cluster + OIDC Provider만 유지

# ============================================
# Cluster Outputs
# ============================================
output "cluster_id" {
  description = "EKS cluster ID"
  value       = aws_eks_cluster.cluster.id
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.cluster.name
}

output "cluster_arn" {
  description = "EKS cluster ARN"
  value       = aws_eks_cluster.cluster.arn
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = aws_eks_cluster.cluster.endpoint
}

output "cluster_version" {
  description = "Kubernetes version of the cluster"
  value       = aws_eks_cluster.cluster.version
}

output "cluster_platform_version" {
  description = "Platform version for the cluster"
  value       = aws_eks_cluster.cluster.platform_version
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required for cluster authentication"
  value       = aws_eks_cluster.cluster.certificate_authority[0].data
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster (auto-created by EKS)"
  value       = aws_eks_cluster.cluster.vpc_config[0].cluster_security_group_id
}

output "cluster_oidc_issuer_url" {
  description = "The URL on the EKS cluster OIDC Issuer"
  value       = aws_eks_cluster.cluster.identity[0].oidc[0].issuer
}

# ============================================
# OIDC Provider Outputs
# ============================================
output "oidc_provider_arn" {
  description = "ARN of the OIDC Provider for EKS (used for IRSA)"
  value       = aws_iam_openid_connect_provider.cluster.arn
}

output "oidc_provider" {
  description = "OIDC provider URL without https:// prefix (used for IAM trust policies)"
  value       = local.oidc_provider
}

# ============================================
# IAM Role Outputs
# ============================================
output "cluster_iam_role_name" {
  description = "IAM role name of the EKS cluster"
  value       = aws_iam_role.cluster.name
}

output "cluster_iam_role_arn" {
  description = "IAM role ARN of the EKS cluster"
  value       = aws_iam_role.cluster.arn
}