output "ingress_name" {
  description = "Ingress name"
  value       = kubernetes_ingress_v1.this.metadata[0].name
}

output "ingress_hostname" {
  description = "ALB DNS name"
  value       = try(kubernetes_ingress_v1.this.status[0].load_balancer[0].ingress[0].hostname, "pending")
}

output "load_balancer_name" {
  description = "ALB name"
  value       = var.load_balancer_name
}
