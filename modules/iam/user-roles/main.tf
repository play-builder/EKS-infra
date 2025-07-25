data "aws_caller_identity" "current" {}

locals {
  map_users = [
    for user in var.admin_iam_users : {
      userarn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${user}"
      username = user
      groups   = ["system:masters"]
    }
  ]
  map_roles = [
    for role_arn in var.readonly_iam_roles : {
      rolearn  = role_arn
      username = element(split("/", role_arn), length(split("/", role_arn)) - 1)  # Extract role name safely
      groups   = ["view"]
    }
  ]
}