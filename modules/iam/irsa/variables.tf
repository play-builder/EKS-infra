# ============================================
# IRSA Module Variables (Common)
# 모든 IRSA 사용 케이스에서 재사용
# ============================================

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


# [핵심] 정책 내용을 변수로 받아서 동적으로 생성
variable "iam_policy_statements" {
  description = "IAM Policy Statement 목록"
  type = list(object({
    sid       = optional(string)
    effect    = string
    actions   = list(string)
    resources = list(string)
  }))
}

variable "create_service_account" {
  description = "Kubernetes Service Account 생성 여부 (Helm 사용 시 false 권장)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "리소스 태그"
  type        = map(string)
  default     = {}
}



