

# -----------------------------------------------------------------------------
# Ingress 출력
# -----------------------------------------------------------------------------
output "ingress_name" {
  description = "Ingress 이름"
  value       = kubernetes_ingress_v1.this.metadata[0].name
}

output "ingress_hostname" {
  description = "ALB DNS 이름"
  value       = try(kubernetes_ingress_v1.this.status[0].load_balancer[0].ingress[0].hostname, "pending")
}

output "load_balancer_name" {
  description = "ALB 이름"
  value       = var.load_balancer_name
}