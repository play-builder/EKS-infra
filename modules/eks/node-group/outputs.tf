# ============================================
# EKS Node Group Module - Outputs
# ============================================

# ============================================
# Node Group Outputs
# ============================================
output "node_group_id" {
  description = "The ID of the EKS Node Group"
  value       = aws_eks_node_group.this.id
}

output "node_group_arn" {
  description = "The ARN of the EKS Node Group"
  value       = aws_eks_node_group.this.arn
}

output "node_group_status" {
  description = "The status of the EKS Node Group"
  value       = aws_eks_node_group.this.status
}

output "node_group_version" {
  description = "The Kubernetes version of the Node Group"
  value       = aws_eks_node_group.this.version
}

output "node_group_resources" {
  description = "Resources associated with the node group (autoscaling groups, etc.)"
  value       = aws_eks_node_group.this.resources
}

# ============================================
# IAM Role Outputs
# ============================================
output "node_role_arn" {
  description = "The ARN of the Node IAM Role (for aws-auth ConfigMap)"
  value       = aws_iam_role.node_group.arn
}

output "node_role_name" {
  description = "The name of the Node IAM Role"
  value       = aws_iam_role.node_group.name
}

# ============================================
# Autoscaling Group Outputs
# ============================================
output "autoscaling_group_names" {
  description = "The names of the Auto Scaling Groups"
  value       = [for resource in aws_eks_node_group.this.resources[0].autoscaling_groups : resource.name]
}