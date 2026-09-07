# A platform publisher can write only its own private mirror repository.
# Both the workflow and this subject use environment:production; GitHub protects main separately.
locals {
  platform_publisher = var.platform_image_publisher == null ? {} : { platform = var.platform_image_publisher }
  platform_subject   = var.platform_image_publisher == null ? null : "repo:${var.platform_image_publisher.github_owner}@${var.platform_image_publisher.github_owner_id}/${var.platform_image_publisher.repository_name}@${var.platform_image_publisher.repository_id}:environment:production"
}

resource "aws_ecr_repository" "platform" {
  for_each             = local.platform_publisher
  name                 = each.value.ecr_repository_name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
  tags = { Layer = "registry", Purpose = "platform-image-mirror" }
  lifecycle { prevent_destroy = true }
}

# No expiry policy: active Istio revisions and OCI attestations need reviewed retention.
resource "aws_ecr_repository_policy" "platform" {
  for_each   = local.platform_publisher
  repository = aws_ecr_repository.platform[each.key].name
  policy     = data.aws_iam_policy_document.org_pull.json
}

data "aws_iam_policy_document" "platform_trust" {
  for_each = local.platform_publisher
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
      values   = [local.platform_subject]
    }
  }
}

resource "aws_iam_role" "platform_publisher" {
  for_each             = local.platform_publisher
  name                 = "${var.project_name}-github-platform-image-publisher"
  assume_role_policy   = data.aws_iam_policy_document.platform_trust[each.key].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "platform_publish" {
  for_each = local.platform_publisher
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "MirrorAndAttestDedicatedRepository"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload",
      "ecr:DescribeImages", "ecr:DescribeRepositories", "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload", "ecr:ListImages", "ecr:ListImageReferrers",
      "ecr:PutImage", "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.platform[each.key].arn]
  }
}

resource "aws_iam_role_policy" "platform_publish" {
  for_each = local.platform_publisher
  name     = "mirror-and-attest-platform-images"
  role     = aws_iam_role.platform_publisher[each.key].id
  policy   = data.aws_iam_policy_document.platform_publish[each.key].json
}

module "registry_scanning" {
  source = "../../../modules/security/ecr-registry-scanning"
  required_repositories = toset(concat(
    [local.image_repository],
    var.platform_image_publisher == null ? [] : [var.platform_image_publisher.ecr_repository_name],
  ))
  configuration = {
    ownership_mode                  = var.registry_scanning.ownership_mode
    scan_type                       = "ENHANCED"
    scan_frequency                  = "CONTINUOUS_SCAN"
    repository_filters              = var.registry_scanning.repository_filters
    scan_on_push_repository_filters = var.registry_scanning.scan_on_push_repository_filters
  }
  ownership_handoff = var.registry_scanning.ownership_handoff
}

# Import the existing account/region singleton before reviewing its diff. Never issue a blind create.
# AWS defaults to BASIC even in a new account. Import reads it; only the reviewed apply changes it.
import {
  for_each = var.registry_scanning.ownership_mode == "terraform" ? toset(["registry"]) : toset([])
  to       = module.registry_scanning.aws_ecr_registry_scanning_configuration.this[0]
  id       = data.aws_caller_identity.current.account_id
}
