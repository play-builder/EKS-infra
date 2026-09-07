# Bootstrap is operator-managed. CI never owns its own IAM roles, OIDC provider or boundary.
# Provisioning permissions belong to the external identity/security owner, not a generic PowerUser policy.
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = { Project = var.project_name, ManagedBy = "Terraform" }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  github_issuer      = "token.actions.githubusercontent.com"
  repository_subject = "repo:${var.github_owner}@${var.github_owner_id}/${var.infra_repository_name}@${var.infra_repository_id}"
  infra_main_subject = "${local.repository_subject}:ref:refs/heads/main"
  github_environment = var.environment == "prod" ? "production" : var.environment
  ci_environments = {
    plan  = "${local.github_environment}-plan"
    apply = local.github_environment
    drift = "${local.github_environment}-drift"
  }
  ci_subjects        = { for purpose, name in local.ci_environments : purpose => "${local.repository_subject}:environment:${name}" }
  oidc_provider_arn  = var.oidc_provider_mode == "create" ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.external[0].arn
  account_arn_prefix = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}"
  legacy_role_arn    = "${local.account_arn_prefix}:role/${var.project_name}-github-${var.environment}-infra"
  state_bucket_arn   = "arn:${data.aws_partition.current.partition}:s3:::${var.state_bucket_name}"
  state_keys = var.environment == "recovery" ? ["recovery/03-database/terraform.tfstate"] : concat([
    "${var.environment}/01-network/terraform.tfstate",
    "${var.environment}/02-eks/terraform.tfstate",
    "${var.environment}/03-platform/terraform.tfstate",
    "${var.environment}/04-workloads/argocd/terraform.tfstate",
  ], var.environment == "prod" ? ["prod/03-database/terraform.tfstate"] : [])
  state_object_arns = [for key in local.state_keys : "${local.state_bucket_arn}/${key}"]
  lock_object_arns  = [for key in local.state_keys : "${local.state_bucket_arn}/${key}.tflock"]
  protected_identity_arns = distinct(concat(
    [local.legacy_role_arn, local.oidc_provider_arn],
    [for role in var.external_ci_roles : role.role_arn],
    [for role in var.external_ci_roles : role.permissions_boundary_arn],
  ))
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.oidc_provider_mode == "create" ? 1 : 0
  url            = "https://${local.github_issuer}"
  client_id_list = ["sts.amazonaws.com"]
  tags           = { Name = "github-actions-oidc" }
  lifecycle { prevent_destroy = true }
}

data "aws_iam_openid_connect_provider" "external" {
  count = var.oidc_provider_mode == "external" ? 1 : 0
  arn   = var.external_oidc_provider_arn
  lifecycle {
    postcondition {
      condition = (
        self.arn == "${local.account_arn_prefix}:oidc-provider/${local.github_issuer}" &&
        trimsuffix(trimprefix(self.url, "https://"), "/") == local.github_issuer &&
        contains(self.client_id_list, "sts.amazonaws.com")
      )
      error_message = "External OIDC must be the current account's GitHub issuer with sts.amazonaws.com audience."
    }
  }
}

# Preserve the old address/name for a reviewed in-place retirement. No implicit IAM deletion or state removal.
# Deny new sessions and all operations, including old sessions once IAM propagates the inline policy.
data "aws_iam_policy_document" "infra_trust" {
  statement {
    effect  = "Deny"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.github_issuer}:sub"
      values   = [local.infra_main_subject]
    }
  }
}

resource "aws_iam_role" "infra" {
  name                 = "${var.project_name}-github-${var.environment}-infra"
  description          = "RETIRED: use externally owned purpose-specific CI roles; all API access is denied."
  assume_role_policy   = data.aws_iam_policy_document.infra_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "infra_extra" {
  statement {
    sid       = "RetiredRoleDenyAll"
    effect    = "Deny"
    actions   = ["*"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "infra_extra" {
  name   = "terraform-iam-and-state"
  role   = aws_iam_role.infra.id
  policy = data.aws_iam_policy_document.infra_extra.json
}
