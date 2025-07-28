
variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "playdevops"
}

variable "namespace" {
  description = "Kubernetes namespace for Online Boutique"
  type        = string
  default     = "online-boutique"
}

variable "create_namespace" {
  description = "Create namespace if not exists"
  type        = bool
  default     = true
}

variable "helm_release_name" {
  description = "Helm release name"
  type        = string
  default     = "online-boutique"
}

variable "helm_chart_version" {
  description = "Online Boutique Helm chart version"
  type        = string
  default     = "0.10.4"
}

variable "enable_load_generator" {
  description = "Enable load generator (DISABLE for Production!)"
  type        = bool
  default     = false 
}

variable "enable_network_policies" {
  description = "Enable Kubernetes Network Policies"
  type        = bool
  default     = false 
}

variable "enable_ingress" {
  description = "Enable ALB Ingress for external access"
  type        = bool
  default     = true
}

variable "ingress_hostname" {
  description = "Hostname for Ingress (e.g., shop.playdevops.click)"
  type        = string
  default     = ""
}

variable "ingress_class_name" {
  description = "Ingress Class name"
  type        = string
  default     = "alb"
}

variable "ingress_group_name" {
  description = "ALB Ingress Group name"
  type        = string
  default     = "playdevops-alb"
}

variable "alb_scheme" {
  description = "ALB scheme (internet-facing or internal)"
  type        = string
  default     = "internet-facing"
}

variable "enable_hpa" {
  description = "Enable Horizontal Pod Autoscaler"
  type        = bool
  default     = true
}

variable "hpa_min_replicas" {
  description = "Minimum replicas for HPA"
  type        = number
  default     = 2 
}

variable "hpa_max_replicas" {
  description = "Maximum replicas for HPA"
  type        = number
  default     = 10 
}

variable "hpa_target_cpu" {
  description = "Target CPU utilization for HPA"
  type        = number
  default     = 70
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
