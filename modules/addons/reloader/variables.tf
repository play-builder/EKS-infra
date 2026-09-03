variable "chart_version" {
  description = "Pinned Stakater Reloader Helm chart version"
  type        = string
  default     = "2.2.16"
}

variable "namespace" {
  description = "Namespace for the Reloader controller"
  type        = string
  default     = "reloader"
}

variable "release_name" {
  description = "Helm release name"
  type        = string
  default     = "reloader"
}
