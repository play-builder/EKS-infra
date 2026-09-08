variable "addon_version" {
  description = "Explicit ADOT EKS add-on version verified for the target Kubernetes version and AWS Region"
  type        = string
  nullable    = false
  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+-eksbuild\\.[0-9]+$", var.addon_version))
    error_message = "Select an exact ADOT version returned by aws eks describe-addon-versions."
  }
}

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

variable "enable_collection" {
  description = "Plan-time switch for collector resources; must not depend on an AMP computed endpoint"
  type        = bool
  default     = true
}

variable "amp_workspace_endpoint" {
  description = "AMP workspace Prometheus endpoint URL"
  type        = string
  default     = ""
  validation {
    condition     = !var.enable_collection || trimspace(var.amp_workspace_endpoint) != ""
    error_message = "AMP endpoint is required when collector resources are enabled."
  }
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

  validation {
    condition     = !var.enable_xray || (var.enable_collection && trimspace(var.amp_workspace_endpoint) != "")
    error_message = "enable_xray requires a non-empty amp_workspace_endpoint so the collector is created."
  }
}

variable "cert_manager_chart_version" {
  description = "cert-manager chart required by the ADOT EKS add-on"
  type        = string
  default     = "v1.21.1"
}

variable "collector_image" {
  description = "ADOT collector image pinned to an OCI index digest for amd64 and arm64"
  type        = string
  default     = "public.ecr.aws/aws-observability/aws-otel-collector:v0.49.0@sha256:d2bdfff2c377c3d71d78bd5d9ce9862fd535b12134a5739d87a07801297cf9fd"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
