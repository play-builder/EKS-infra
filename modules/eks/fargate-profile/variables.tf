variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "fargate_profile_name" {
  description = "Name of the Fargate Profile"
  type        = string
}

variable "subnet_ids" {
  description = "List of Private Subnet IDs for Fargate Pods"
  type        = list(string)
}

variable "selectors" {
  description = "List of selectors (namespace/labels) for Fargate Pods"
  type        = list(object({
    namespace = string
    labels    = map(string)
  }))
}

variable "common_tags" {
  description = "Map of common tags"
  type        = map(string)
  default     = {}
}