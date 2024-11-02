variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster's OIDC Provider"
  type        = string
}

# [수정] oidc_issuer → oidc_provider로 변경하고 내부에서 https:// 추가
variable "oidc_provider" {
  description = "OIDC provider URL without https:// prefix"
  type        = string
}

variable "aws_region" {
  description = "AWS Region"
  type        = string
}

variable "chart_version" {
  description = "Helm chart version for cluster-autoscaler"
  type        = string
  default     = "9.37.0" # 최신 버전으로 업데이트
}

variable "common_tags" {
  description = "Map of common tags"
  type        = map(string)
  default     = {}
}