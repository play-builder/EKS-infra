data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name               = "${var.environment}-${var.project_name}"
  availability_zones = length(var.availability_zones) > 0 ? var.availability_zones : slice(data.aws_availability_zones.available.names, 0, 3)

  common_tags = merge(
    var.tags,
    {
      CourseId           = var.course_id
      Environment        = var.environment
      PlatformInstanceId = var.platform_instance_id
      Owner              = var.owner
      CostCenter         = var.cost_center
      Project            = var.project_name
      division           = var.division
      ManagedBy          = "Terraform"
      Layer              = "network"
    }
  )


  eks_cluster_name = coalesce(var.cluster_name, "${local.name}-eks")
}

module "vpc" {
  source = "../../../modules/networking/vpc"

  name               = local.name
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = local.availability_zones

  public_subnet_cidrs   = var.public_subnet_cidrs
  private_subnet_cidrs  = var.private_subnet_cidrs
  database_subnet_cidrs = var.database_subnet_cidrs

  enable_nat_gateway      = var.enable_nat_gateway
  single_nat_gateway      = var.single_nat_gateway
  one_nat_gateway_per_az  = var.one_nat_gateway_per_az
  production_nat_topology = var.production_nat_topology

  enable_vpc_flow_logs           = var.enable_vpc_flow_logs
  vpc_flow_log_retention_in_days = var.vpc_flow_log_retention_in_days
  vpc_flow_log_kms_key_arn       = module.log_key.kms_key_arn

  enable_dns_hostnames = var.enable_dns_hostnames
  enable_dns_support   = var.enable_dns_support

  eks_cluster_name = local.eks_cluster_name

  tags = local.common_tags
}
