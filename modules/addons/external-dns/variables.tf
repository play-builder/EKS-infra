variable "cluster_name" {
  description = "EKS Cluster name (used for TXT Owner ID)"
  type        = string
}

variable "aws_region" {
  description = "AWS Region"
  type        = string
}

variable "oidc_provider_arn" {
  description = "OIDC Provider ARN for IRSA"
  type        = string
}

variable "oidc_provider" {
  description = "OIDC Provider URL (without https://)"
  type        = string
}

variable "chart_version" {
  description = "Helm chart version for external-dns"
  type        = string
  default     = "1.14.5" # 최신 안정 버전
}

variable "hosted_zone_id" {
  description = "Route 53 Hosted Zone ID to manage (Scope Down for Security)"
  type        = string
}

variable "domain_filters" {
  description = "List of domains to manage (e.g. ['playdevops.click'])"
  type        = list(string)
}

variable "namespace" {
  description = "Namespace to install ExternalDNS"
  type        = string
  default     = "kube-system" # [중요] 실무 권장 기본값
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}