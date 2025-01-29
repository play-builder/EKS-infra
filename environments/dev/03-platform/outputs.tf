output "ebs_csi_driver_iam_role_arn" {
  description = "IAM Role ARN for EBS CSI Driver"
  value       = var.enable_ebs_csi_driver ? module.ebs_csi_driver[0].iam_role_arn : null
}

output "ebs_csi_driver_addon_id" {
  description = "EBS CSI Driver add-on ID"
  value       = var.enable_ebs_csi_driver ? module.ebs_csi_driver[0].addon_id : null
}

output "acm_certificate_arn" {
  description = "The ARN of the public wildcard ACM certificate"
  value       = module.acm.acm_certificate_arn
}

output "ebs_csi_driver_addon_version" {
  description = "EBS CSI Driver add-on version"
  value       = var.enable_ebs_csi_driver ? module.ebs_csi_driver[0].addon_version : null
}

output "ebs_csi_verification_commands" {
  description = "Shell commands to verify EBS CSI Driver; run manually or via script if enable_ebs_csi_driver = true"
  value       = <<-EOT
    aws eks list-addons --cluster-name ${local.eks_cluster_name}
    aws eks describe-addon --cluster-name ${local.eks_cluster_name} --addon-name aws-ebs-csi-driver
    kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-ebs-csi-driver
    kubectl -n kube-system get deploy ebs-csi-controller
    kubectl -n kube-system get ds ebs-csi-node
    kubectl -n kube-system get sa ebs-csi-controller-sa
    kubectl -n kube-system get sa ebs-csi-controller-sa -o jsonpath='{.metadata.annotations.eks\\.amazonaws\\.com/role-arn}'
    kubectl get storageclass
    kubectl get sc ebs-sc
    cat <<EOF | kubectl apply -f -
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: test-ebs-pvc
    spec:
      accessModes:
        - ReadWriteOnce
      storageClassName: gp3
      resources:
        requests:
          storage: 1Gi
    EOF
    kubectl get pvc test-ebs-pvc
    kubectl get pv
    kubectl delete pvc test-ebs-pvc
  EOT
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

output "alb_controller_verification_commands" {
  description = "Shell commands to verify AWS Load Balancer Controller (if enabled)"

  value = <<-EOT
  %{if var.enable_alb_controller}
  kubectl -n kube-system get deployment aws-load-balancer-controller
  kubectl -n kube-system describe deployment aws-load-balancer-controller

  kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller

  kubectl -n kube-system get sa aws-load-balancer-controller
  kubectl -n kube-system describe sa aws-load-balancer-controller

  kubectl -n kube-system get sa aws-load-balancer-controller \\
    -o jsonpath='{.metadata.annotations.eks\\.amazonaws\\.com/role-arn}'

  kubectl -n kube-system get svc aws-load-balancer-webhook-service
  kubectl -n kube-system describe svc aws-load-balancer-webhook-service

  kubectl get ingressclass
  kubectl describe ingressclass ${var.alb_controller_ingress_class_name}

  kubectl -n kube-system logs -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50

  cat <<EOF | kubectl apply -f -
  apiVersion: networking.k8s.io/v1
  kind: Ingress
  metadata:
    name: test-ingress
    annotations:
      alb.ingress.kubernetes.io/scheme: internet-facing
      alb.ingress.kubernetes.io/target-type: ip
  spec:
    ingressClassName: ${var.alb_controller_ingress_class_name}
    rules:
      - http:
          paths:
            - path: /
              pathType: Prefix
              backend:
                service:
                  name: test-service
                  port:
                    number: 80
  EOF

  kubectl get ingress test-ingress
  kubectl describe ingress test-ingress
  kubectl delete ingress test-ingress
  %{else}
  %{endif}
  EOT
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
