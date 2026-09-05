variable "eks_cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "environment" {
  description = "Exact Mini Commerce namespace environment and remote-write identity."
  type        = string
  default     = "dev"
  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "oidc_provider_arn" {
  description = "OIDC Provider ARN for IRSA"
  type        = string
}

variable "oidc_provider" {
  description = "OIDC Provider URL without https://"
  type        = string
}

variable "amp_workspace_endpoint" {
  description = "AMP workspace Prometheus endpoint URL"
  type        = string
  default     = ""
}

variable "amp_workspace_arn" {
  description = "AMP workspace ARN allowed for remote write"
  type        = string
  default     = "*"
}

variable "enable_xray" {
  description = "Enable OTLP trace ingestion and the AWS X-Ray exporter"
  type        = bool
  default     = false
}

variable "cert_manager_chart_version" {
  description = "cert-manager chart required by the ADOT EKS add-on"
  type        = string
  default     = "v1.21.1"
}

variable "collector_image" {
  description = "Pinned multi-architecture ADOT collector image"
  type        = string
  default     = "public.ecr.aws/aws-observability/aws-otel-collector:v0.49.0"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
