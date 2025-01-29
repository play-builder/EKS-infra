output "ebs_csi_driver_iam_role_arn" {
  description = "IAM Role ARN for EBS CSI Driver"
  value       = var.enable_ebs_csi_driver ? module.ebs_csi_driver[0].iam_role_arn : null
}

output "ebs_csi_driver_addon_id" {
  description = "EBS CSI Driver add-on ID"
  value       = var.enable_ebs_csi_driver ? module.ebs_csi_driver[0].addon_id : null
}

output "ebs_csi_driver_addon_version" {
  description = "EBS CSI Driver add-on version"
  value       = var.enable_ebs_csi_driver ? module.ebs_csi_driver[0].addon_version : null
}

output "acm_certificate_arn" {
  description = "The ARN of the public wildcard ACM certificate"
  value       = module.acm.acm_certificate_arn
}

output "alb_controller_iam_role_arn" {
  description = "IAM Role ARN for AWS Load Balancer Controller"
  value       = var.enable_alb_controller ? module.aws_load_balancer_controller[0].iam_role_arn : null
}

output "alb_controller_helm_release_name" {
  description = "Helm release name for AWS Load Balancer Controller"
  value       = var.enable_alb_controller ? module.aws_load_balancer_controller[0].helm_release_name : null
}

output "alb_controller_helm_release_status" {
  description = "Helm release status for AWS Load Balancer Controller"
  value       = var.enable_alb_controller ? module.aws_load_balancer_controller[0].helm_release_status : null
}

output "ingress_class_name" {
  description = "AWS ALB IngressClass name"
  value       = length(module.aws_load_balancer_controller) > 0 ? module.aws_load_balancer_controller[0].ingress_class_name : null
}

output "metrics_server_release_name" {
  description = "Metrics Server Helm release name"
  value       = var.enable_metrics_server ? module.metrics_server[0].helm_release_name : null
}

output "cluster_autoscaler_iam_role_arn" {
  description = "Cluster Autoscaler IAM Role ARN"
  value       = var.enable_cluster_autoscaler ? module.cluster_autoscaler[0].iam_role_arn : null
}

output "container_insights_namespace" {
  description = "Container Insights namespace"
  value       = var.enable_container_insights ? module.container_insights[0].namespace : null
}

output "verification_commands" {
  description = "Commands to verify platform components"
  value       = <<-EOT
    kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-ebs-csi-driver
    kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller
    kubectl -n kube-system get pods -l app.kubernetes.io/name=external-dns
    kubectl -n kube-system get pods -l app.kubernetes.io/name=metrics-server
    kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-cluster-autoscaler
    kubectl -n amazon-cloudwatch get pods
  EOT
}
