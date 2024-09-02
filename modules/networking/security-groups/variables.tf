variable "name" {
  description = "Name of the security group"
  type        = string
}

variable "description" {
  description = "Description of the security group"
  type        = string
  default     = "Managed by Terraform"
}

variable "vpc_id" {
  description = "VPC ID where the security group will be created"
  type        = string
}

variable "ingress_rules" {
  description = "A list of ingress rules (maps)"
  type        = list(any)
  default     = []
}

variable "egress_rules" {
  description = "A list of egress rules (maps)"
  type        = list(any)
  default     = []
}

variable "common_tags" {
  description = "Map of common tags"
  type        = map(string)
  default     = {}
}
