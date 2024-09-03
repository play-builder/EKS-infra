data "aws_caller_identity" "current" {}

locals {
  # 1. Format admin user mappings
  map_users = [
    for user in var.admin_iam_users : {
      userarn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/${user}"
      username = user
      groups   = ["system:masters"] # 'system:masters' = Full Cluster Admin
    }
  ]
  
  # 2. Format role/group mappings
  map_roles = concat(
    [
      for group in var.developer_iam_groups : {
        rolearn  = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:group/${group}"
        username = group
        groups   = ["view", "edit"] # (Example custom RBAC groups)
      }
    ],
    [
      for role_arn in var.readonly_iam_roles : {
        rolearn  = role_arn
        username = replace(role_arn, "/.*$/", "") # Use role name as username
        groups   = ["view"] # (Example custom RBAC group)
      }
    ]
  )
}