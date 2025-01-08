output "cluster_id" {
  description = "EKS Cluster ID"
  value       = module.eks_cluster.cluster_id
}

output "cluster_name" {
  description = "EKS Cluster name"
  value       = module.eks_cluster.cluster_name
}

output "cluster_arn" {
  description = "EKS Cluster ARN"
  value       = module.eks_cluster.cluster_arn
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks_cluster.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes version for the cluster"
  value       = module.eks_cluster.cluster_version
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data"
  value       = module.eks_cluster.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = module.eks_cluster.cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC Provider"
  value       = module.eks_cluster.oidc_provider_arn
}

output "oidc_provider" {
  description = "OIDC provider URL (without https://)"
  value       = module.eks_cluster.oidc_provider
}

output "private_node_group_id" {
  description = "Private Node Group ID"
  value       = var.enable_private_node_group ? module.node_group_private[0].node_group_id : null
}

output "private_node_group_arn" {
  description = "Private Node Group ARN"
  value       = var.enable_private_node_group ? module.node_group_private[0].node_group_arn : null
}

output "private_node_group_status" {
  description = "Private Node Group status"
  value       = var.enable_private_node_group ? module.node_group_private[0].node_group_status : null
}

output "private_node_role_arn" {
  description = "Private Node IAM Role ARN"
  value       = var.enable_private_node_group ? module.node_group_private[0].node_role_arn : null
}

output "bastion_instance_id" {
  description = "Bastion Host instance ID"
  value       = var.enable_bastion ? module.bastion[0].instance_id : null
}

output "bastion_public_ip" {
  description = "Bastion Host Elastic IP"
  value       = var.enable_bastion ? module.bastion[0].public_ip : null
}

output "bastion_security_group_id" {
  description = "Bastion Host security group ID"
  value       = var.enable_bastion ? module.bastion[0].security_group_id : null
}

output "configure_kubectl" {
  description = "Configure kubectl command"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks_cluster.cluster_name}"
}
