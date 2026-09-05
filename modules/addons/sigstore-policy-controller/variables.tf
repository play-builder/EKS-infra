variable "environment" { type = string }
variable "name" { type = string }
variable "tags" {
  type = map(string)
  validation {
    condition     = alltrue([for k in ["PlatformInstanceId", "Owner", "CostCenter", "Environment"] : try(trimspace(var.tags[k]) != "", false)])
    error_message = "Mandatory ownership tags are required."
  }
}
variable "replicas" {
  type = number
  validation {
    condition     = var.replicas >= (var.environment == "prod" ? 2 : 1)
    error_message = "Production webhook requires at least two replicas."
  }
}
variable "oidc_provider" { type = string }
variable "oidc_provider_arn" { type = string }
variable "repository_arns" {
  type = set(string)
  validation {
    condition     = length(var.repository_arns) > 0 && alltrue([for a in var.repository_arns : can(regex("^arn:aws:ecr:[a-z0-9-]+:[0-9]{12}:repository/[^*?]+$", a))])
    error_message = "Use exact old/new image ECR repository ARNs."
  }
}
variable "api_server_cidrs" {
  type = set(string)
  validation {
    condition     = length(var.api_server_cidrs) > 0 && alltrue([for c in var.api_server_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "Exact API endpoint/service CIDRs required."
  }
}
variable "https_egress_cidrs" {
  type = set(string)
  validation {
    condition     = length(var.https_egress_cidrs) > 0 && alltrue([for c in var.https_egress_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "Supply approved ECR/Sigstore/GitHub HTTPS destination CIDRs."
  }
}
