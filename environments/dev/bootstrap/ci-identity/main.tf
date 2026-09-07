# dev account: GitHub OIDC provider and the role GitHub Actions assumes to run Terraform for this account.
# Local operators apply dev roots directly; this role is used by the reviewed CI apply workflow.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.project_name
      ManagedBy = "Terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  github_issuer      = "token.actions.githubusercontent.com"
  infra_main_subject = "repo:${var.github_owner}@${var.github_owner_id}/${var.infra_repository_name}@${var.infra_repository_id}:ref:refs/heads/main"
  oidc_provider_arn  = var.oidc_provider_mode == "create" ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.external[0].arn
  state_bucket_arn   = "arn:aws:s3:::${var.state_bucket_name}"
  state_keys = [
    "${var.environment}/01-network/terraform.tfstate",
    "${var.environment}/02-eks/terraform.tfstate",
    "${var.environment}/03-platform/terraform.tfstate",
    "${var.environment}/04-workloads/argocd/terraform.tfstate",
  ]
  state_object_arns = [for key in local.state_keys : "${local.state_bucket_arn}/${key}"]
  lock_object_arns  = [for key in local.state_keys : "${local.state_bucket_arn}/${key}.tflock"]
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.oidc_provider_mode == "create" ? 1 : 0
  url            = "https://${local.github_issuer}"
  client_id_list = ["sts.amazonaws.com"]

  tags = { Name = "github-actions-oidc" }

  lifecycle {
    prevent_destroy = true
  }
}

data "aws_iam_openid_connect_provider" "external" {
  count = var.oidc_provider_mode == "external" ? 1 : 0
  arn   = var.external_oidc_provider_arn
}

data "aws_iam_policy_document" "infra_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_issuer}:aud"
      values   = ["sts.amazonaws.com"]
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
  assume_role_policy   = data.aws_iam_policy_document.infra_trust.json
  max_session_duration = 3600
}

# Broad service access without IAM/account administration...
resource "aws_iam_role_policy_attachment" "power_user" {
  role       = aws_iam_role.infra.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# ...plus the IAM scope Terraform needs for roles it creates, and state access limited to this account's keys.
# The dev roots name their IAM resources "<environment>-<project>-*" (environments/dev/*/main.tf local.name) and
# 02-eks creates the cluster's own IAM OIDC provider, so both patterns are in scope next to "<project>-*".
data "aws_iam_policy_document" "infra_extra" {
  statement {
    sid    = "ManageProjectRoles"
    effect = "Allow"
    actions = [
      "iam:AttachRolePolicy", "iam:CreateInstanceProfile", "iam:CreatePolicy", "iam:CreatePolicyVersion",
      "iam:CreateRole", "iam:CreateServiceLinkedRole", "iam:DeleteInstanceProfile", "iam:DeletePolicy",
      "iam:DeletePolicyVersion", "iam:DeleteRole", "iam:DeleteRolePolicy", "iam:DetachRolePolicy",
      "iam:GetInstanceProfile", "iam:GetOpenIDConnectProvider", "iam:GetPolicy", "iam:GetPolicyVersion",
      "iam:GetRole", "iam:GetRolePolicy", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
      "iam:ListPolicyVersions", "iam:ListRolePolicies", "iam:PassRole", "iam:PutRolePolicy",
      "iam:TagPolicy", "iam:TagRole", "iam:UntagPolicy", "iam:UntagRole", "iam:UpdateAssumeRolePolicy",
      "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
      "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
      "iam:TagOpenIDConnectProvider", "iam:UntagOpenIDConnectProvider",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.project_name}-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.project_name}-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/${var.project_name}-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${var.environment}-${var.project_name}-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:policy/${var.environment}-${var.project_name}-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:instance-profile/${var.environment}-${var.project_name}-*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/*",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${local.github_issuer}",
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/oidc.eks.${var.aws_region}.amazonaws.com/id/*",
    ]
  }

  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket", "s3:GetBucketVersioning"]
    resources = [local.state_bucket_arn]
  }

  statement {
    sid       = "ReadWriteStateObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = local.state_object_arns
  }

  statement {
    sid       = "ManageLockObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = local.lock_object_arns
  }
}

resource "aws_iam_role_policy" "infra_extra" {
  name   = "terraform-iam-and-state"
  role   = aws_iam_role.infra.id
  policy = data.aws_iam_policy_document.infra_extra.json
}
