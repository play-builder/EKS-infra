data "terraform_remote_state" "eks" {
  backend = "s3"

  config = {
    bucket = "playdevops-infra-tf-prod"
    key    = "prod/02-eks/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = "${var.project_name}-infra-tf-${var.environment}"
    key    = "${var.environment}/01-network/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  name             = "${var.environment}-${var.project_name}"
  eks_cluster_name = data.terraform_remote_state.eks.outputs.cluster_name
  vpc_id           = data.terraform_remote_state.network.outputs.vpc_id

  common_tags = merge(
    var.tags,
    {
      Environment = var.environment
      Project     = var.project_name
      division    = var.division  
      ManagedBy   = "Terraform"
      Layer       = "platform"
    }
  )
}

module "ebs_csi_driver" {
  source = "../../../modules/addons/ebs-csi-driver"
  count  = var.enable_ebs_csi_driver ? 1 : 0

  name             = "${local.name}-ebs-csi-driver"
  eks_cluster_name = local.eks_cluster_name

  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  oidc_provider     = data.terraform_remote_state.eks.outputs.oidc_provider

  addon_version               = var.ebs_csi_driver_addon_version
  resolve_conflicts_on_create = var.ebs_csi_driver_resolve_conflicts_on_create

  use_aws_managed_policy = var.ebs_csi_driver_use_aws_managed_policy

  service_account_name = "ebs-csi-controller-sa"
  namespace            = "kube-system"

  tags = local.common_tags
}

module "aws_load_balancer_controller" {
  source = "../../../modules/addons/aws-load-balancer-controller"
  count  = var.enable_alb_controller ? 1 : 0

  name             = "${local.name}-alb-controller"
  eks_cluster_name = local.eks_cluster_name
  vpc_id           = local.vpc_id
  aws_region       = var.aws_region

  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  oidc_provider     = data.terraform_remote_state.eks.outputs.oidc_provider

  helm_chart_version = var.alb_controller_chart_version

  ecr_account_id = split(".", var.alb_controller_image_repository)[0]

  ingress_class_name = var.alb_controller_ingress_class_name
  is_default_class   = var.alb_controller_is_default

  common_tags = local.common_tags
}

module "external_dns" {
  source = "../../../modules/addons/external-dns"
  count  = var.enable_external_dns ? 1 : 0

  cluster_name = local.eks_cluster_name
  aws_region   = var.aws_region

  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  oidc_provider     = data.terraform_remote_state.eks.outputs.oidc_provider

  hosted_zone_id = var.hosted_zone_id
  domain_filters = var.external_dns_domain_filters

  namespace     = "kube-system"
  chart_version = var.external_dns_chart_version

  tags = local.common_tags
}

module "acm" {
  source = "../../../modules/security/acm"

  domain_name = var.acm_domain_name

  subject_alternative_names = [
    "*.${var.acm_domain_name}"
  ]

  hosted_zone_id = var.hosted_zone_id
  tags           = local.common_tags
}

module "metrics_server" {
  source = "../../../modules/addons/metrics-server"
  count  = var.enable_metrics_server ? 1 : 0

  chart_version = var.metrics_server_chart_version
}

module "cluster_autoscaler" {
  source = "../../../modules/addons/cluster-autoscaler"
  count  = var.enable_cluster_autoscaler ? 1 : 0

  cluster_name      = local.eks_cluster_name
  aws_region        = var.aws_region
  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  oidc_provider     = data.terraform_remote_state.eks.outputs.oidc_provider

  chart_version = var.cluster_autoscaler_chart_version
  common_tags   = local.common_tags

  depends_on = [module.metrics_server]
}

module "container_insights" {
  source = "../../../modules/addons/container-insights"
  count  = var.enable_container_insights ? 1 : 0

  eks_cluster_name = local.eks_cluster_name
  aws_region       = var.aws_region

  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  oidc_provider     = data.terraform_remote_state.eks.outputs.oidc_provider

  cloudwatch_agent_chart_version = var.cloudwatch_agent_chart_version
  fluent_bit_chart_version       = var.fluent_bit_chart_version

  tags = local.common_tags
}
