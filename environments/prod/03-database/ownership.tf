variable "project_name" {
  type    = string
  default = "playdevops"
}
locals {
  owned_tags = merge(var.tags, {
    Project     = var.project_name
    AccountId   = var.expected_account_id
    Region      = var.aws_region
    Environment = "prod"
    Layer       = "database"
    ManagedBy   = "Terraform"
  })
}
