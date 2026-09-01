variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used by state buckets and shared resources"
  type        = string
  default     = "playdevops"
}

variable "github_org" {
  description = "GitHub organization"
  type        = string
  default     = "play-builder"
}

variable "infra_role_name" {
  description = "GitHub Actions role for EKS-infra"
  type        = string
  default     = "playdevops-github-eks-infra"
}

variable "infra_oidc_subjects" {
  description = "Exact GitHub OIDC subjects allowed to assume the infrastructure role"
  type        = set(string)
  default = [
    "repo:play-builder@42942042/EKS-infra@405337777:ref:refs/heads/main"
  ]
}

variable "sample_app_push_role_name" {
  description = "GitHub Actions role that can push only the sample-app image"
  type        = string
  default     = "playdevops-github-sample-app-push"
}

variable "sample_app_oidc_subjects" {
  description = "Exact GitHub OIDC subjects allowed to push sample-app images"
  type        = set(string)
  default = [
    "repo:play-builder@42942042/cicd-course-sample-app@1352247019:ref:refs/heads/main",
    "repo:play-builder@42942042/cicd-course-sample-app@1352247019:ref:refs/heads/dev"
  ]
}

variable "sample_app_ecr_repository" {
  description = "Private ECR repository for sample-app OCI images"
  type        = string
  default     = "playdevops/sample-app"
}

variable "helm_chart_ecr_repository" {
  description = "Private ECR repository for sample-app Helm OCI artifacts"
  type        = string
  default     = "playdevops/sample-app-chart"
}

variable "ecr_keep_last_images" {
  description = "Number of tagged course images kept in ECR"
  type        = number
  default     = 30

  validation {
    condition     = var.ecr_keep_last_images >= 10
    error_message = "ecr_keep_last_images must be at least 10."
  }
}

variable "tags" {
  description = "Additional resource tags"
  type        = map(string)
  default     = {}
}
