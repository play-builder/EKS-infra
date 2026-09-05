locals {
  required_tags = {
    CourseId           = var.course_id
    AccountId          = var.billing_account_id
    Region             = "us-east-1"
    Project            = var.project_name
    Layer              = "finops"
    PlatformInstanceId = var.platform_instance_id
    Owner              = var.owner
    CostCenter         = var.cost_center
    Environment        = "prod"
    ManagedBy          = "Terraform"
  }
}
module "finops" {
  source              = "../../../modules/finops"
  providers           = { aws = aws.billing }
  name                = "${var.project_name}-prod"
  billing_account_id  = var.billing_account_id
  workload_account_id = var.workload_account_id
  workload_region     = var.aws_region
  finops = {
    monthly_budget_usd          = var.finops.monthly_budget_usd
    alert_threshold_percentages = [50, 80, 100]
    anomaly_threshold_usd       = var.finops.anomaly_threshold_usd
    notification_topic_arn      = var.finops.notification_topic_arn
    required_tags               = local.required_tags
  }
}
