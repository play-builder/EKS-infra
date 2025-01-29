variable "name" {
  description = "Name of the service using IRSA"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "kube-system"
}

variable "service_account_name" {
  description = "Kubernetes Service Account name"
  type        = string
}

variable "oidc_provider_arn" {
  description = "OIDC provider ARN"
  type        = string
}

variable "oidc_provider" {
  description = "OIDC provider URL (without https://)"
  type        = string
}

variable "iam_policy_statements" {
  description = "IAM Policy Statement list"
  type = list(object({
    sid       = optional(string)
    effect    = string
    actions   = list(string)
    resources = list(string)
  }))
}

variable "create_service_account" {
  description = "Whether to create Kubernetes Service Account (recommended false when using Helm)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}
