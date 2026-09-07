# network account: central container registry and the GitHub Actions identity that pushes to it.
# dev/prod accounts only pull; pull is granted to every account in the Organization.

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
  github_issuer     = "token.actions.githubusercontent.com"
  app_main_subject  = "repo:${var.github_owner}@${var.github_owner_id}/${var.app_repository_name}@${var.app_repository_id}:ref:refs/heads/main"
  oidc_provider_arn = var.oidc_provider_mode == "create" ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.external[0].arn
  image_repository  = var.project_name
  chart_repository  = "${var.project_name}-chart"
  repository_arns   = [aws_ecr_repository.image.arn, aws_ecr_repository.chart.arn]
}

# ---- GitHub OIDC provider (one per account) ----
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

# ---- ECR repositories ----
resource "aws_ecr_repository" "image" {
  name                 = local.image_repository
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = { Layer = "registry" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ecr_repository" "chart" {
  name                 = local.chart_repository
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = { Layer = "registry" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ecr_lifecycle_policy" "image" {
  repository = aws_ecr_repository.image.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after seven days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 7
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the latest sha- tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = var.ecr_keep_last_images
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ---- Cross-account pull: any principal inside the Organization ----
data "aws_iam_policy_document" "org_pull" {
  statement {
    sid    = "AllowPullFromOrganization"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:ListImages",
    ]

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = [var.org_id]
    }
  }
}

resource "aws_ecr_repository_policy" "image" {
  repository = aws_ecr_repository.image.name
  policy     = data.aws_iam_policy_document.org_pull.json
}

resource "aws_ecr_repository_policy" "chart" {
  repository = aws_ecr_repository.chart.name
  policy     = data.aws_iam_policy_document.org_pull.json
}

# ---- Trust: only mini-commerce main (immutable subject) ----
data "aws_iam_policy_document" "app_main_trust" {
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
      values   = [local.app_main_subject]
    }
  }
}

# ---- Role 1: image push ----
resource "aws_iam_role" "image_push" {
  name                 = "${var.project_name}-github-image-push"
  assume_role_policy   = data.aws_iam_policy_document.app_main_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "image_push" {
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PushToProjectRepositories"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:ListImages",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = local.repository_arns
  }
}

resource "aws_iam_role_policy" "image_push" {
  name   = "ecr-push"
  role   = aws_iam_role.image_push.id
  policy = data.aws_iam_policy_document.image_push.json
}

# ---- Role 2: attestation verify (reads images, pushes OCI referrers) ----
resource "aws_iam_role" "attest_verify" {
  name                 = "${var.project_name}-github-attest-verify"
  assume_role_policy   = data.aws_iam_policy_document.app_main_trust.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "attest_verify" {
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "ReadImagesAndWriteReferrers"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:ListImages",
      "ecr:ListImageReferrers",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.image.arn]
  }
}

resource "aws_iam_role_policy" "attest_verify" {
  name   = "ecr-attest-verify"
  role   = aws_iam_role.attest_verify.id
  policy = data.aws_iam_policy_document.attest_verify.json
}
