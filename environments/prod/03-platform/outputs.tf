output "acm_certificate_arn" {
  description = "Wildcard ACM certificate ARN used when HTTPS is enabled"
  value       = module.acm.acm_certificate_arn
}

output "ebs_csi_driver_iam_role_arn" {
  description = "IAM role for the EBS CSI controller"
  value       = var.enable_ebs_csi_driver ? module.ebs_csi_driver[0].iam_role_arn : null
}

output "alb_controller_iam_role_arn" {
  description = "IAM role for AWS Load Balancer Controller"
  value       = var.enable_alb_controller ? module.aws_load_balancer_controller[0].iam_role_arn : null
}

output "alb_controller_helm_release_status" {
  description = "AWS Load Balancer Controller Helm release status"
  value       = var.enable_alb_controller ? module.aws_load_balancer_controller[0].helm_release_status : null
}

output "metrics_server_release_name" {
  description = "Metrics Server Helm release name"
  value       = var.enable_metrics_server ? module.metrics_server[0].helm_release_name : null
}

output "amp_workspace_id" {
  description = "Environment-local AMP workspace ID"
  value       = var.enable_amp ? module.amp[0].workspace_id : null
}

output "amp_workspace_endpoint" {
  description = "AMP Prometheus endpoint used by ADOT and Argo Rollouts"
  value       = var.enable_amp ? module.amp[0].workspace_prometheus_endpoint : null
}

output "adot_collector_role_arn" {
  description = "Least-privilege ADOT remote-write role"
  value       = var.enable_adot_collector ? module.adot_collector[0].iam_role_arn : null
}

output "adot_addon_version" {
  description = "ADOT EKS add-on version selected by AWS"
  value       = var.enable_adot_collector ? module.adot_collector[0].addon_version : null
}

output "amg_workspace_endpoint" {
  description = "Optional Amazon Managed Grafana endpoint"
  value       = var.enable_amg ? module.amg[0].workspace_endpoint : null
}

output "verification_commands" {
  description = "Read-only commands for platform readiness"
  value       = <<-EOT
    kubectl -n kube-system get deploy aws-load-balancer-controller
    kubectl -n kube-system get deploy external-dns
    kubectl -n kube-system get deploy metrics-server
    kubectl get crd gateways.gateway.networking.k8s.io
    kubectl get crd loadbalancerconfigurations.gateway.k8s.aws
    kubectl -n opentelemetry-operator-system get opentelemetrycollector
    kubectl -n opentelemetry-operator-system get pods
  EOT
}

