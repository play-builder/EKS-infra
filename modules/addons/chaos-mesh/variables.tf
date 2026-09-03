variable "enable_chaos_mesh" {
  description = "Enable the Ch25 Chaos Mesh controller"
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_chaos_mesh || var.environment == "dev"
    error_message = "CHAOS_MESH_DEV_ONLY: Chaos Mesh may be enabled only in dev."
  }
}

variable "environment" {
  description = "Course environment owning this controller"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "prod"], var.environment)
    error_message = "environment must be dev or prod."
  }
}

variable "course_id" {
  description = "CourseId ownership binding for the controller and fault resources"
  type        = string
  default     = "course-2026"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{7,62}$", var.course_id))
    error_message = "course_id must be a unique 8-63 character lowercase identifier."
  }
}

variable "namespace" {
  description = "Dedicated namespace for the Chaos Mesh control plane"
  type        = string
  default     = "chaos-mesh"

  validation {
    condition     = var.namespace == "chaos-mesh"
    error_message = "Chaos Mesh must use the dedicated chaos-mesh namespace."
  }
}

variable "allowed_namespaces" {
  description = "Application namespaces eligible for Ch25 faults"
  type        = list(string)
  default     = ["app-dev"]

  validation {
    condition = length(var.allowed_namespaces) > 0 && alltrue([
      for namespace in var.allowed_namespaces : startswith(namespace, "app-") && namespace != "app-prod"
    ])
    error_message = "Chaos Mesh fault namespace allowlist must contain only non-prod app namespaces."
  }
}

variable "max_fault_duration_seconds" {
  description = "Maximum duration for one Ch25 fault"
  type        = number
  default     = 60

  validation {
    condition     = var.max_fault_duration_seconds >= 1 && var.max_fault_duration_seconds <= 300 && floor(var.max_fault_duration_seconds) == var.max_fault_duration_seconds
    error_message = "max_fault_duration_seconds must be an integer between 1 and 300."
  }
}

variable "max_faults" {
  description = "Maximum number of simultaneous faults admitted by the course"
  type        = number
  default     = 1

  validation {
    condition     = var.max_faults == 1
    error_message = "Ch25 admits exactly one fault per game-day run."
  }
}

variable "chart_version" {
  description = "Pinned Chaos Mesh Helm chart version verified for the course"
  type        = string
  default     = "2.8.0"
}

variable "controller_cloud_wait_seconds" {
  description = "Declared readiness wait budget for the controller"
  type        = number
  default     = 600

  validation {
    condition     = var.controller_cloud_wait_seconds >= 60 && var.controller_cloud_wait_seconds <= 1800
    error_message = "controller_cloud_wait_seconds must be between 60 and 1800 seconds."
  }
}
