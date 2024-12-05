variable "domain_name" {
  description = "Primary domain name (Apex domain recommended)"
  type        = string
}

variable "subject_alternative_names" {
  description = "List of alternative domains (e.g. *.example.com)"
  type        = list(string)
  default     = []
}

variable "hosted_zone_id" {
  description = "Route53 Hosted Zone ID for DNS validation"
  type        = string
}

variable "tags" {
  description = "Tags"
  type        = map(string)
  default     = {}
}