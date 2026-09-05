data "aws_caller_identity" "current" {}
module "backup" {
  source                  = "../../modules/storage/protected-backup"
  bucket_name             = "${var.project_name}-argocd-backup-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  administrator_role_arns = var.administrator_role_arns
  operator_role_arns      = var.operator_role_arns
  retention_days          = var.retention_days
  tags = merge(var.tags, {
    CourseId    = var.course_id
    Project     = var.project_name
    AccountId   = data.aws_caller_identity.current.account_id
    Region      = var.aws_region
    Environment = "prod"
    Layer       = "platform-backup"
  })
}
