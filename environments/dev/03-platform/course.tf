variable "enable_course_resources" {
  description = "Create course-specific Gateway CRDs, secret shell, and IRSA roles"
  type        = bool
  default     = true
}

variable "enable_gateway_api" {
  description = "Install Gateway API v1.6.0 and AWS LBC v3.5.0 Gateway CRDs"
  type        = bool
  default     = true
}

variable "secret_recovery_window_in_days" {
  description = "Secrets Manager recovery window. Use 7 in the course; set 0 only for disposable labs."
  type        = number
  default     = 7

  validation {
    condition     = var.secret_recovery_window_in_days == 0 || (var.secret_recovery_window_in_days >= 7 && var.secret_recovery_window_in_days <= 30)
    error_message = "secret_recovery_window_in_days must be 0 or between 7 and 30."
  }
}

variable "course_application_namespace" {
  description = "Namespace where the sample application is deployed"
  type        = string
  default     = ""
}

variable "external_secrets_reader_service_account" {
  description = "ServiceAccount used by SecretStore JWT authentication"
  type        = string
  default     = "external-secrets-reader"
}

variable "rollouts_service_account" {
  description = "Argo Rollouts controller ServiceAccount"
  type        = string
  default     = "argo-rollouts"
}

locals {
  application_namespace = var.course_application_namespace != "" ? var.course_application_namespace : "app-${var.environment}"
}

resource "kubernetes_storage_class_v1" "course_gp3" {
  count = var.enable_course_resources && var.enable_course_storage_class && var.enable_ebs_csi_driver ? 1 : 0

  metadata {
    name = "course-gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "false"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    "type"      = "gp3"
    "encrypted" = "true"
    "fsType"    = "ext4"
  }

  depends_on = [module.ebs_csi_driver]
}

data "kubectl_file_documents" "gateway_api" {
  content = file("${path.root}/../../../vendor/gateway-api/v1.6.0/standard-install.yaml")
}

data "kubectl_file_documents" "aws_lbc_gateway" {
  content = file("${path.root}/../../../vendor/aws-load-balancer-controller/v3.5.0/gateway-crds.yaml")
}

resource "kubectl_manifest" "gateway_api" {
  for_each = var.enable_course_resources && var.enable_gateway_api ? data.kubectl_file_documents.gateway_api.manifests : {}

  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true
  wait_for_rollout  = false
}

resource "kubectl_manifest" "aws_lbc_gateway" {
  for_each = var.enable_course_resources && var.enable_gateway_api ? data.kubectl_file_documents.aws_lbc_gateway.manifests : {}

  yaml_body         = each.value
  server_side_apply = true
  force_conflicts   = true
  wait_for_rollout  = false

  depends_on = [kubectl_manifest.gateway_api]
}

resource "aws_secretsmanager_secret" "sample_app" {
  count = var.enable_course_resources ? 1 : 0

  name                    = "sample-app/${var.environment}/app-secrets"
  description             = "Secret shell for sample-app ${var.environment}; values are added outside Terraform"
  recovery_window_in_days = var.secret_recovery_window_in_days

  tags = merge(local.common_tags, {
    Application = "sample-app"
  })
}

module "external_secrets_reader_irsa" {
  source = "../../../modules/iam/irsa"
  count  = var.enable_course_resources ? 1 : 0

  name = "${local.name}-external-secrets-reader"

  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  oidc_provider     = data.terraform_remote_state.eks.outputs.oidc_provider

  namespace            = local.application_namespace
  service_account_name = var.external_secrets_reader_service_account

  create_service_account = false

  iam_policy_statements = [
    {
      sid       = "ReadEnvironmentSecret"
      effect    = "Allow"
      actions   = ["secretsmanager:DescribeSecret", "secretsmanager:GetSecretValue"]
      resources = [aws_secretsmanager_secret.sample_app[0].arn]
    }
  ]

  tags = local.common_tags
}

module "rollouts_amp_irsa" {
  source = "../../../modules/iam/irsa"
  count  = var.enable_course_resources && var.enable_amp ? 1 : 0

  name = "${local.name}-argo-rollouts-amp"

  oidc_provider_arn = data.terraform_remote_state.eks.outputs.oidc_provider_arn
  oidc_provider     = data.terraform_remote_state.eks.outputs.oidc_provider

  namespace            = "argo-rollouts"
  service_account_name = var.rollouts_service_account

  create_service_account = false

  iam_policy_statements = [
    {
      sid    = "QueryAmp"
      effect = "Allow"
      actions = [
        "aps:GetLabels",
        "aps:GetMetricMetadata",
        "aps:GetSeries",
        "aps:QueryMetrics"
      ]
      resources = [module.amp[0].workspace_arn]
    }
  ]

  tags = local.common_tags
}

output "course_secret_name" {
  description = "Secrets Manager shell populated after apply"
  value       = var.enable_course_resources ? aws_secretsmanager_secret.sample_app[0].name : null
}

output "external_secrets_reader_role_arn" {
  description = "IRSA role written into the external-secrets-reader ServiceAccount"
  value       = var.enable_course_resources ? module.external_secrets_reader_irsa[0].iam_role_arn : null
}

output "rollouts_amp_role_arn" {
  description = "IRSA role written into the Argo Rollouts controller ServiceAccount"
  value       = var.enable_course_resources && var.enable_amp ? module.rollouts_amp_irsa[0].iam_role_arn : null
}

output "gateway_crd_versions" {
  description = "Vendored Gateway API and AWS LBC Gateway CRD versions"
  value = {
    gateway_api = "1.6.0"
    aws_lbc     = "3.5.0"
  }
}

output "course_storage_class_name" {
  description = "Non-default encrypted gp3 StorageClass for the Stateful course lab"
  value       = var.enable_course_resources && var.enable_course_storage_class && var.enable_ebs_csi_driver ? kubernetes_storage_class_v1.course_gp3[0].metadata[0].name : null
}
