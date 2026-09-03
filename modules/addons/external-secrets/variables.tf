variable "chart_version" {
  description = "Pinned External Secrets Helm chart version"
  type        = string
  default     = "2.10.0"
}

variable "namespace" {
  description = "Namespace that owns the External Secrets controller release"
  type        = string
  default     = "external-secrets"
}

variable "release_name" {
  description = "Stable Helm release name used by the ownership handoff"
  type        = string
  default     = "external-secrets"
}
