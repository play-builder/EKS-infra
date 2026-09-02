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
  default     = "1.21.1"
}

variable "hosted_zone_id" {
  description = "Route 53 Hosted Zone ID to manage (Scope Down for Security)"
  type        = string
}

variable "domain_filters" {
  description = "List of domains to manage (e.g. ['playdevops.click'])"
  type        = list(string)
}

variable "exclude_domains" {
  description = "Subdomains that this ExternalDNS deployment must not manage"
  type        = list(string)
  default     = []
}

variable "namespace" {
  description = "Namespace to install ExternalDNS"
  type        = string
  default     = "kube-system"
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}

variable "sources" {
  description = "Kubernetes resource sources watched by ExternalDNS"
  type        = list(string)
  default     = ["service", "gateway-httproute"]
}

variable "policy" {
  description = "ExternalDNS record update policy"
  type        = string
  default     = "upsert-only"

  validation {
    condition     = contains(["create-only", "upsert-only", "sync"], var.policy)
    error_message = "policy must be create-only, upsert-only, or sync."
  }
}
