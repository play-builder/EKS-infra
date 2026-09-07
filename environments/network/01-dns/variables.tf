variable "aws_region" {
  description = "Provider Region. Route 53 is global; the value only selects the API endpoint."
  type        = string

  validation {
    condition     = contains(["ap-northeast-2", "us-east-1"], var.aws_region)
    error_message = "aws_region must be ap-northeast-2 or us-east-1."
  }
}

variable "project_name" {
  type    = string
  default = "mini-commerce"
}

variable "course_id" {
  type = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{7,62}$", var.course_id))
    error_message = "course_id must be an 8-63 character lowercase identifier."
  }
}

variable "root_domain" {
  description = "Apex domain without trailing dot, e.g. example.com"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.root_domain))
    error_message = "root_domain must be a lowercase domain name without a trailing dot."
  }
}

variable "child_zones" {
  description = "Delegated child zones: FQDN => name servers reported by the child account zone"
  type        = map(list(string))
  default     = {}

  validation {
    condition     = alltrue([for name, servers in var.child_zones : length(servers) == 4])
    error_message = "Every child zone must list exactly the four Route 53 name servers of that zone."
  }
}
