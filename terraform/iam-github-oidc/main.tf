locals {
  common_tags = merge(var.tags, {
    CourseId    = var.course_id
    Project     = var.project_name
    AccountId   = data.aws_caller_identity.current.account_id
    Region      = var.aws_region
    Environment = "shared"
    ManagedBy   = "Terraform"
    Layer       = "shared"
  })

  external_oidc_account_id = var.oidc_provider_mode == "external" ? split(":", var.external_oidc_provider_arn)[4] : null
  oidc_provider_arn = var.oidc_provider_mode == "create" ? (
    aws_iam_openid_connect_provider.github[0].arn
  ) : data.aws_iam_openid_connect_provider.external[0].arn

  terraform_state_keys = toset([
    "shared/iam-github-oidc/terraform.tfstate",
    "shared/github-governance/terraform.tfstate",
    "dev/01-network/terraform.tfstate",
    "dev/02-eks/terraform.tfstate",
    "dev/03-platform/terraform.tfstate",
    "dev/04-workloads/argocd/terraform.tfstate",
    "prod/01-network/terraform.tfstate",
    "prod/02-eks/terraform.tfstate",
    "prod/03-platform/terraform.tfstate",
    "prod/04-workloads/argocd/terraform.tfstate",
  ])
  terraform_state_object_arns = toset(flatten([
    for bucket_arn in var.state_bucket_arns : [
      for state_key in local.terraform_state_keys : "${bucket_arn}/${state_key}"
    ]
  ]))
  terraform_lock_object_arns = toset([
    for state_arn in local.terraform_state_object_arns : "${state_arn}.tflock"
  ])
}

data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.oidc_provider_mode == "create" ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  tags = merge(local.common_tags, {
    Name = "GitHub-Actions-OIDC-Provider"
  })

  lifecycle {
    prevent_destroy = true
  }
}

data "aws_iam_openid_connect_provider" "external" {
  count = var.oidc_provider_mode == "external" ? 1 : 0
  arn   = var.external_oidc_provider_arn
}

resource "terraform_data" "oidc_ownership_marker" {
  input = {
    mode       = var.oidc_provider_mode
    provider   = local.oidc_provider_arn
    account_id = data.aws_caller_identity.current.account_id
    issuer     = "https://token.actions.githubusercontent.com"
    audience   = "sts.amazonaws.com"
  }

  triggers_replace = [var.oidc_provider_mode, local.oidc_provider_arn]

  lifecycle {
    prevent_destroy = true

    precondition {
      condition = var.oidc_provider_mode != "external" || (
        local.external_oidc_account_id == data.aws_caller_identity.current.account_id &&
        trimprefix(data.aws_iam_openid_connect_provider.external[0].url, "https://") == "token.actions.githubusercontent.com" &&
        contains(data.aws_iam_openid_connect_provider.external[0].client_id_list, "sts.amazonaws.com")
      )
      error_message = "External OIDC provider must belong to the current account and use the exact GitHub issuer and STS audience."
    }
  }
}

resource "aws_ecr_repository" "sample_app" {
  name                 = var.sample_app_ecr_repository
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  encryption_configuration {
    encryption_type = "AES256"
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.common_tags, {
    Name = var.sample_app_ecr_repository
  })
}

resource "aws_ecr_lifecycle_policy" "sample_app" {
  repository = aws_ecr_repository.sample_app.name

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
        description  = "Keep the latest course images"
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

resource "aws_ecr_repository" "helm_chart" {
  name                 = var.helm_chart_ecr_repository
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  encryption_configuration {
    encryption_type = "AES256"
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.common_tags, {
    Name = var.helm_chart_ecr_repository
  })
}

data "aws_iam_policy_document" "infra_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.infra_oidc_subjects
    }
  }
}

resource "aws_iam_role" "infra" {
  name               = var.infra_role_name
  description        = "Role assumed by EKS-infra GitHub Actions through immutable OIDC subjects"
  assume_role_policy = data.aws_iam_policy_document.infra_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_policy" "infra" {
  name        = "${var.infra_role_name}-policy"
  description = "Course infrastructure plan and apply permissions"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "CourseInfrastructure"
        Effect   = "Allow"
        Action   = ["acm:*", "aps:*", "ec2:*", "eks:*", "elasticloadbalancing:*", "logs:*", "route53:*", "secretsmanager:*"]
        Resource = "*"
      },
      {
        Sid    = "CourseIam"
        Effect = "Allow"
        Action = [
          "iam:AttachRolePolicy",
          "iam:CreatePolicy",
          "iam:CreateRole",
          "iam:DeletePolicy",
          "iam:DeleteRole",
          "iam:DetachRolePolicy",
          "iam:GetOpenIDConnectProvider",
          "iam:GetPolicy",
          "iam:GetPolicyVersion",
          "iam:GetRole",
          "iam:ListAttachedRolePolicies",
          "iam:ListInstanceProfilesForRole",
          "iam:ListPolicyVersions",
          "iam:PassRole",
          "iam:PutRolePolicy",
          "iam:DeleteRolePolicy",
          "iam:TagOpenIDConnectProvider",
          "iam:TagPolicy",
          "iam:TagRole"
        ]
        Resource = "*"
      },
      {
        Sid      = "TerraformStateBucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = sort(tolist(var.state_bucket_arns))
      },
      {
        Sid      = "TerraformStateObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = sort(tolist(local.terraform_state_object_arns))
      },
      {
        Sid      = "TerraformStateLockObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = sort(tolist(local.terraform_lock_object_arns))
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "infra" {
  role       = aws_iam_role.infra.name
  policy_arn = aws_iam_policy.infra.arn
}

data "aws_iam_policy_document" "sample_app_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.sample_app_oidc_subjects
    }
  }
}

resource "aws_iam_role" "sample_app_push" {
  name               = var.sample_app_push_role_name
  description        = "Push-only role for cicd-course-sample-app"
  assume_role_policy = data.aws_iam_policy_document.sample_app_assume_role.json
  tags               = local.common_tags
}

resource "aws_iam_policy" "sample_app_push" {
  name        = "${var.sample_app_push_role_name}-policy"
  description = "Push multi-architecture sample-app images to one ECR repository"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "PushSampleApp"
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]
        Resource = aws_ecr_repository.sample_app.arn
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "sample_app_push" {
  role       = aws_iam_role.sample_app_push.name
  policy_arn = aws_iam_policy.sample_app_push.arn
}
