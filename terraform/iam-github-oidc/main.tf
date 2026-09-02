locals {
  common_tags = merge(var.tags, {
    Course    = "cicd-gitops"
    ManagedBy = "Terraform"
    Layer     = "shared"
  })
}

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  tags = merge(local.common_tags, {
    Name = "GitHub-Actions-OIDC-Provider"
  })
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
      identifiers = [aws_iam_openid_connect_provider.github.arn]
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
          "iam:CreateOpenIDConnectProvider",
          "iam:CreatePolicy",
          "iam:CreateRole",
          "iam:DeleteOpenIDConnectProvider",
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
        Sid      = "TerraformStateBuckets"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:ListBucket", "s3:PutObject"]
        Resource = ["arn:aws:s3:::${var.project_name}-infra-tf-*", "arn:aws:s3:::${var.project_name}-infra-tf-*/*"]
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
      identifiers = [aws_iam_openid_connect_provider.github.arn]
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
