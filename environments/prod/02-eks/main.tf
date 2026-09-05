
data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = "${var.project_name}-infra-tf-${var.environment}"
    key    = "${var.environment}/01-network/terraform.tfstate"
    region = var.aws_region
  }
}

locals {
  name = "${var.environment}-${var.project_name}"

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
      Layer              = "eks"
    }
  )

  vpc_id             = data.terraform_remote_state.network.outputs.vpc_id
  public_subnet_ids  = data.terraform_remote_state.network.outputs.public_subnet_ids
  private_subnet_ids = data.terraform_remote_state.network.outputs.private_subnet_ids
}

module "eks_cluster" {
  source = "../../../modules/eks/cluster/"

  name            = local.name
  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id             = local.vpc_id
  public_subnet_ids  = local.public_subnet_ids
  private_subnet_ids = local.private_subnet_ids

  cluster_service_ipv4_cidr            = var.cluster_service_ipv4_cidr
  cluster_endpoint_private_access      = var.cluster_endpoint_private_access
  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  authentication_mode                         = var.authentication_mode
  bootstrap_cluster_creator_admin_permissions = var.bootstrap_cluster_creator_admin_permissions

  cluster_enabled_log_types     = var.cluster_enabled_log_types
  cluster_log_retention_in_days = var.cluster_log_retention_in_days
  cluster_log_kms_key_arn       = data.terraform_remote_state.network.outputs.logging_contract.kms_key_arn
  environment                   = var.environment
  depends_on                    = [terraform_data.logging_identity]

  vpc_cni_addon_version                 = var.vpc_cni_addon_version
  vpc_cni_enable_network_policy         = var.vpc_cni_enable_network_policy
  vpc_cni_network_policy_enforcing_mode = var.vpc_cni_network_policy_enforcing_mode
  vpc_cni_strict_gate_evidence_file     = var.vpc_cni_strict_gate_evidence_file

  tags = local.common_tags
}

module "node_group_private" {
  source = "../../../modules/eks/node-group/"
  count  = var.enable_private_node_group ? 1 : 0

  cluster_name         = module.eks_cluster.cluster_name
  cluster_version      = module.eks_cluster.cluster_version
  node_release_version = var.node_release_version

  name            = local.name
  node_group_name = var.private_node_group_name
  node_group_type = "private"
  subnet_ids      = local.private_subnet_ids

  desired_size = var.private_node_group_desired_size
  min_size     = var.private_node_group_min_size
  max_size     = var.private_node_group_max_size

  instance_types = var.private_node_group_instance_types
  capacity_type  = var.node_group_capacity_type
  ami_type       = var.node_group_ami_type
  disk_size      = var.node_group_disk_size

  max_unavailable_percentage = var.node_group_max_unavailable

  ssh_key_name                  = ""
  ssh_source_security_group_ids = []

  enable_ssm        = true
  enable_cloudwatch = true

  kubernetes_labels = {
    Environment  = var.environment
    WorkloadType = "general"
  }

  common_tags = local.common_tags

  depends_on = [module.eks_cluster]
}


module "operator_access" {
  source = "../../../modules/compute/operator-access"

  name                      = local.name
  vpc_id                    = local.vpc_id
  subnet_id                 = var.operator_access.subnet_id
  cluster_name              = module.eks_cluster.cluster_name
  cluster_arn               = module.eks_cluster.cluster_arn
  cluster_security_group_id = module.eks_cluster.cluster_security_group_id
  trusted_sso_principal_arn = var.operator_access.trusted_sso_principal_arn
  ami_id                    = var.operator_access.ami_id
  instance_type             = var.operator_access.instance_type
  mode                      = var.operator_access.mode
  tags                      = local.common_tags

  depends_on = [module.eks_cluster]
}
module "managed_addons" {
  source                 = "../../../modules/eks/managed-addons"
  cluster_name           = module.eks_cluster.cluster_name
  managed_addon_versions = var.managed_addon_versions
  tags                   = local.common_tags
  depends_on             = [module.node_group_private]
}
module "access_entries" {
  source       = "../../../modules/eks/access-entries"
  cluster_name = module.eks_cluster.cluster_name
  tags         = local.common_tags
  access_entries = merge(var.access_entries, {
    platform-operator = {
      principal_arn = module.operator_access.operator_role_arn
      policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
      scope_type    = "namespace"
      namespaces    = [module.operator_access.authorization_namespace, "app-prod"]
      break_glass   = false
    }
  })
}
