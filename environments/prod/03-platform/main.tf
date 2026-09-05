data "terraform_remote_state" "eks" {
  backend = "s3"

  config = {
    bucket = "${var.project_name}-infra-tf-${var.environment}"
    key    = "${var.environment}/02-eks/terraform.tfstate"
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

  external_secrets_adoption = var.external_secrets_adoption_evidence_path == null ? null : try(
    jsondecode(file(var.external_secrets_adoption_evidence_path)),
    null
  )
  external_secrets_adoption_release        = try(local.external_secrets_adoption.release, null)
  external_secrets_adoption_release_before = try(local.external_secrets_adoption_release.before, null)
  external_secrets_adoption_release_after  = try(local.external_secrets_adoption_release.after, null)
  external_secrets_adoption_terraform      = try(local.external_secrets_adoption.terraform, null)

  external_secrets_adoption_valid = var.external_secrets_ownership_mode == "fresh" || (
    try(toset(keys(local.external_secrets_adoption)) == toset(["schemaVersion", "evidenceGrade", "environment", "region", "clusterArn", "handoffSha256", "release", "terraform", "observedAt", "expiresAt"]), false) &&
    try(local.external_secrets_adoption.schemaVersion, "") == "course.platform-release-adoption/v1" &&
    try(local.external_secrets_adoption.evidenceGrade, "") == "CLOUD_RUNTIME" &&
    try(local.external_secrets_adoption.environment, "") == var.environment &&
    try(local.external_secrets_adoption.region, "") == var.aws_region &&
    try(local.external_secrets_adoption.clusterArn, "") == data.terraform_remote_state.eks.outputs.cluster_arn &&
    try(can(regex("^sha256:[0-9a-f]{64}$", local.external_secrets_adoption.handoffSha256)), false) &&
    try(toset(keys(local.external_secrets_adoption_release)) == toset(["before", "after"]), false) &&
    try(toset(keys(local.external_secrets_adoption_release_before)) == toset(["namespace", "name", "chart", "version", "revision", "status", "valuesSha256", "helmStorageObjectUid", "workloadUids", "crdUids"]), false) &&
    try(toset(keys(local.external_secrets_adoption_release_after)) == toset(["namespace", "name", "chart", "version", "revision", "status", "valuesSha256", "helmStorageObjectUid", "workloadUids", "crdUids"]), false) &&
    try(local.external_secrets_adoption_release_before == local.external_secrets_adoption_release_after, false) &&
    try(local.external_secrets_adoption_release_before.namespace, "") == "external-secrets" &&
    try(local.external_secrets_adoption_release_before.name, "") == "external-secrets" &&
    try(local.external_secrets_adoption_release_before.chart, "") == "external-secrets" &&
    try(local.external_secrets_adoption_release_before.version, "") == var.external_secrets_chart_version &&
    try(local.external_secrets_adoption_release_before.revision >= 1 && floor(local.external_secrets_adoption_release_before.revision) == local.external_secrets_adoption_release_before.revision, false) &&
    try(local.external_secrets_adoption_release_before.status, "") == "deployed" &&
    try(can(regex("^sha256:[0-9a-f]{64}$", local.external_secrets_adoption_release_before.valuesSha256)), false) &&
    try(length(local.external_secrets_adoption_release_before.helmStorageObjectUid) > 0, false) &&
    try(
      length(local.external_secrets_adoption_release_before.workloadUids) > 0 &&
      alltrue([
        for item in local.external_secrets_adoption_release_before.workloadUids :
        toset(keys(item)) == toset(["kind", "name", "uid"]) &&
        length(item.kind) > 0 && length(item.name) > 0 && length(item.uid) > 0
      ]),
      false
    ) &&
    try(
      length(local.external_secrets_adoption_release_before.crdUids) > 0 &&
      alltrue([
        for item in local.external_secrets_adoption_release_before.crdUids :
        toset(keys(item)) == toset(["name", "uid"]) &&
        length(item.name) > 0 && length(item.uid) > 0
      ]),
      false
    ) &&
    try(toset(keys(local.external_secrets_adoption_terraform)) == toset(["address", "stateLineage", "stateSerial", "imported", "planActions"]), false) &&
    try(local.external_secrets_adoption_terraform.address, "") == "module.external_secrets[0].helm_release.this" &&
    try(can(regex("^[0-9a-fA-F-]{36}$", local.external_secrets_adoption_terraform.stateLineage)), false) &&
    try(local.external_secrets_adoption_terraform.stateSerial >= 1 && floor(local.external_secrets_adoption_terraform.stateSerial) == local.external_secrets_adoption_terraform.stateSerial, false) &&
    try(local.external_secrets_adoption_terraform.imported, false) == true &&
    try(jsonencode(local.external_secrets_adoption_terraform.planActions) == "[]", false) &&
    try(
      can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", local.external_secrets_adoption.observedAt)) &&
      formatdate("YYYY-MM-DD'T'hh:mm:ss'Z'", local.external_secrets_adoption.observedAt) == local.external_secrets_adoption.observedAt,
      false
    ) &&
    try(
      can(regex("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", local.external_secrets_adoption.expiresAt)) &&
      formatdate("YYYY-MM-DD'T'hh:mm:ss'Z'", local.external_secrets_adoption.expiresAt) == local.external_secrets_adoption.expiresAt,
      false
    ) &&
    try(timecmp(local.external_secrets_adoption.observedAt, local.external_secrets_adoption.expiresAt) < 0, false)
  )

  common_tags = merge(
    var.tags,
    {
      CourseId    = var.course_id
      Environment = var.environment
      Project     = var.project_name
      division    = var.division
      ManagedBy   = "Terraform"
      Layer       = "platform"
    }
  )
}

resource "terraform_data" "external_secrets_ownership_gate" {
  input = {
    mode         = var.external_secrets_ownership_mode
    evidencePath = var.external_secrets_adoption_evidence_path
  }

  lifecycle {
    precondition {
      condition     = local.external_secrets_adoption_valid
      error_message = "PLATFORM_OWNER_HANDOFF_BLOCKED: adopted mode requires exact CLOUD_RUNTIME no-op adoption evidence."
    }
  }
}

module "external_secrets" {
  source = "../../../modules/addons/external-secrets"
  count  = var.enable_external_secrets ? 1 : 0

  chart_version = var.external_secrets_chart_version

  depends_on = [terraform_data.external_secrets_ownership_gate]
}

module "reloader" {
  source = "../../../modules/addons/reloader"
  count  = var.enable_reloader ? 1 : 0

  chart_version = var.reloader_chart_version
}

module "k6_operator" {
  source = "../../../modules/addons/k6-operator"

  enable_k6_operator = var.enable_k6_operator
  environment        = var.environment
  namespace          = var.k6_operator_namespace
  chart_version      = var.k6_operator_chart_version
}

module "chaos_mesh" {
  source = "../../../modules/addons/chaos-mesh"
  count  = var.enable_chaos_mesh ? 1 : 0

  enable_chaos_mesh             = var.enable_chaos_mesh
  course_id                     = var.course_id
  environment                   = var.environment
  namespace                     = var.chaos_mesh_namespace
  allowed_namespaces            = var.chaos_mesh_allowed_namespaces
  max_fault_duration_seconds    = var.chaos_mesh_max_fault_duration_seconds
  max_faults                    = var.chaos_mesh_max_faults
  chart_version                 = var.chaos_mesh_chart_version
  controller_cloud_wait_seconds = var.chaos_mesh_controller_cloud_wait_seconds
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

resource "aws_eks_addon" "snapshot_controller" {
  count = var.enable_snapshot_controller ? 1 : 0

  cluster_name                = local.eks_cluster_name
  addon_name                  = "snapshot-controller"
  addon_version               = var.snapshot_controller_addon_version
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = merge(local.common_tags, {
    Name = "${local.name}-snapshot-controller-addon"
  })
}

resource "kubectl_manifest" "volume_snapshot_class" {
  for_each = var.enable_snapshot_controller ? {
    (var.volume_snapshot_class_name) = true
  } : {}

  yaml_body = yamlencode({
    apiVersion     = "snapshot.storage.k8s.io/v1"
    kind           = "VolumeSnapshotClass"
    metadata       = { name = each.key }
    driver         = var.snapshot_driver
    deletionPolicy = "Retain"
  })

  server_side_apply = true
  force_conflicts   = true
  wait_for_rollout  = false

  depends_on = [aws_eks_addon.snapshot_controller]
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

  ecr_account_id = var.alb_controller_ecr_account_id

  ingress_class_name = var.alb_controller_ingress_class_name
  is_default_class   = var.alb_controller_is_default

  tags = local.common_tags

  depends_on = [
    kubectl_manifest.gateway_api,
    kubectl_manifest.aws_lbc_gateway,
  ]
}

module "external_dns" {
  source = "../../../modules/addons/external-dns"
  count  = var.enable_external_dns ? 1 : 0

  cluster_name = local.eks_cluster_name
  aws_region   = var.aws_region

  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  oidc_provider     = data.terraform_remote_state.eks.outputs.oidc_provider

  hosted_zone_id  = var.hosted_zone_id
  domain_filters  = var.external_dns_domain_filters
  exclude_domains = var.external_dns_exclude_domains

  namespace     = "kube-system"
  chart_version = var.external_dns_chart_version
  sources       = ["service", "gateway-httproute"]
  policy        = "upsert-only"

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

  chart_version       = var.cluster_autoscaler_chart_version
  environment         = var.environment
  autoscaling_mode    = var.autoscaling_mode
  autoscaler_capacity = var.autoscaler_capacity
  tags                = local.common_tags

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

# --- Amazon Managed Prometheus (AMP) ---
module "amp" {
  source = "../../../modules/addons/amp"
  count  = var.enable_amp ? 1 : 0

  name           = "${local.name}-prometheus"
  retention_days = var.amp_retention_days

  tags = local.common_tags
}

module "adot_collector" {
  source = "../../../modules/addons/adot-collector"
  count  = var.enable_adot_collector ? 1 : 0

  eks_cluster_name = local.eks_cluster_name
  aws_region       = var.aws_region

  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  oidc_provider     = data.terraform_remote_state.eks.outputs.oidc_provider

  amp_workspace_endpoint = var.enable_amp ? module.amp[0].workspace_prometheus_endpoint : ""
  amp_workspace_arn      = var.enable_amp ? module.amp[0].workspace_arn : "*"
  enable_xray            = var.enable_adot_xray

  tags = local.common_tags

  depends_on = [module.amp]
}

module "amp_alerting" {
  source = "../../../modules/addons/amp-alerting"

  enabled             = var.enable_amp && var.enable_amp_alerting
  workspace_id        = var.enable_amp ? module.amp[0].workspace_id : "disabled"
  workspace_arn       = var.enable_amp ? module.amp[0].workspace_arn : "arn:aws:aps:${var.aws_region}:000000000000:workspace/disabled"
  aws_region          = var.aws_region
  enable_sns_delivery = var.enable_amp && var.enable_amp_alerting && var.enable_sns_alert_delivery
  sns_email_endpoint  = var.sns_alert_email_endpoint
  name                = local.name
  tags                = local.common_tags

  depends_on = [module.amp]
}

# --- Amazon Managed Grafana (AMG) ---
module "amg" {
  source = "../../../modules/addons/amg"
  count  = var.enable_amg ? 1 : 0

  name                     = "${local.name}-grafana"
  authentication_providers = var.amg_authentication_providers

  amp_workspace_id = var.enable_amp ? module.amp[0].workspace_id : ""

  tags = local.common_tags

  depends_on = [module.amp]
}
