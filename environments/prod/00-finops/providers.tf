provider "aws" {
  alias               = "billing"
  region              = "us-east-1"
  profile             = var.billing_access.profile
  allowed_account_ids = [var.billing_account_id]
  retry_mode          = "adaptive"
  dynamic "assume_role" {
    for_each = var.billing_access.role_arn == null ? [] : [var.billing_access.role_arn]
    content { role_arn = assume_role.value }
  }
  default_tags { tags = local.required_tags }
}
