variable "app_name" {
  description = "Application name (used for resource naming)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.app_name))
    error_message = "app_name must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "container_image" {
  description = "Container image (e.g., nginx:1.21)"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "default"
}

variable "create_namespace" {
  description = "Whether to create namespace"
  type        = bool
  default     = false
}

variable "replicas" {
  description = "Number of Pod replicas"
  type        = number
  default     = 1

  validation {
    condition     = var.replicas >= 1
    error_message = "replicas must be at least 1."
  }
}

variable "container_port" {
  description = "Container port"
  type        = number
  default     = 80
}

variable "resources" {
  description = "Container resource requests/limits"
  type = object({
    requests = object({
      cpu    = string
      memory = string
    })
    limits = object({
      cpu    = string
      memory = string
    })
  })
  default = {
    requests = {
      cpu    = "100m"
      memory = "128Mi"
    }
    limits = {
      cpu    = "200m"
      memory = "256Mi"
    }
  }
}

variable "health_check_path" {
  description = "Health check HTTP path"
  type        = string
  default     = "/"
}

variable "liveness_probe" {
  description = "Liveness Probe settings (triggers Pod restart)"
  type = object({
    enabled               = bool
    initial_delay_seconds = number
    period_seconds        = number
    timeout_seconds       = number
    failure_threshold     = number
  })
  default = {
    enabled               = true
    initial_delay_seconds = 30
    period_seconds        = 10
    timeout_seconds       = 5
    failure_threshold     = 3
  }
}

variable "readiness_probe" {
  description = "Readiness Probe settings (determines if Pod can receive traffic)"
  type = object({
    enabled               = bool
    initial_delay_seconds = number
    period_seconds        = number
    timeout_seconds       = number
    failure_threshold     = number
  })
  default = {
    enabled               = true
    initial_delay_seconds = 5
    period_seconds        = 5
    timeout_seconds       = 3
    failure_threshold     = 3
  }
}

variable "create_service" {
  description = "Whether to create Service"
  type        = bool
  default     = true
}

variable "service_type" {
  description = "Service type (ClusterIP, NodePort, LoadBalancer)"
  type        = string
  default     = "NodePort"

  validation {
    condition     = contains(["ClusterIP", "NodePort", "LoadBalancer"], var.service_type)
    error_message = "service_type must be one of: ClusterIP, NodePort, LoadBalancer."
  }
}

variable "service_port" {
  description = "Service port"
  type        = number
  default     = 80
}

variable "node_port" {
  description = "NodePort (auto-assigned if not specified)"
  type        = number
  default     = null
}

variable "service_annotations" {
  description = "Additional annotations for Service"
  type        = map(string)
  default     = {}
}

variable "env_vars" {
  description = "Container environment variables"
  type        = map(string)
  default     = {}
}

variable "env_from_secrets" {
  description = "Load environment variables from Secret"
  type = list(object({
    secret_name = string
    optional    = bool
  }))
  default = []
}

variable "env_from_configmaps" {
  description = "Load environment variables from ConfigMap"
  type = list(object({
    configmap_name = string
    optional       = bool
  }))
  default = []
}

variable "volumes" {
  description = "Volumes to mount to Pod"
  type = list(object({
    name       = string
    mount_path = string
    type       = string
    source     = string
    read_only  = bool
  }))
  default = []
}

variable "labels" {
  description = "Labels to add to resources"
  type        = map(string)
  default     = {}
}

variable "annotations" {
  description = "Annotations to add to Deployment"
  type        = map(string)
  default     = {}
}

variable "pod_annotations" {
  description = "Annotations to add to Pod"
  type        = map(string)
  default     = {}
}

variable "image_pull_policy" {
  description = "Image pull policy"
  type        = string
  default     = "IfNotPresent"

  validation {
    condition     = contains(["Always", "IfNotPresent", "Never"], var.image_pull_policy)
    error_message = "image_pull_policy must be one of: Always, IfNotPresent, Never."
  }
}

variable "service_account_name" {
  description = "ServiceAccount name to use"
  type        = string
  default     = null
}

variable "rolling_update" {
  description = "Rolling Update strategy settings"
  type = object({
    max_surge       = string
    max_unavailable = string
  })
  default = {
    max_surge       = "25%"
    max_unavailable = "25%"
  }
}
