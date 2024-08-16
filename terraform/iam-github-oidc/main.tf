# ============================================
# GitHub Actions OIDC Provider
# ============================================
# 역할: GitHub에서 발급한 OIDC 토큰으로 AWS 인증
# 한 번만 생성하면 여러 리포지토리에서 재사용 가능
# ============================================

resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  # GitHub의 OIDC thumbprint (고정값)
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1"
  ]

  tags = {
    Name      = "GitHub-Actions-OIDC-Provider"
    ManagedBy = "Terraform"
  }
}

# ============================================
# IAM Role for GitHub Actions
# ============================================
resource "aws_iam_role" "github_actions" {
  name        = var.role_name
  description = "Role assumed by GitHub Actions via OIDC"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          StringLike = {
            # 특정 리포지토리만 허용
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
          }
        }
      }
    ]
  })

  tags = {
    Name      = var.role_name
    ManagedBy = "Terraform"
  }
}

# ============================================
# IAM Policy - Terraform 실행 권한
# ============================================
resource "aws_iam_policy" "terraform_deployment" {
  name        = "${var.role_name}-terraform-policy"
  description = "Permissions for Terraform to manage EKS infrastructure"

  # 실무에서는 최소 권한만 부여 (Principle of Least Privilege)
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # EC2 관련
      {
        Effect = "Allow"
        Action = [
          "ec2:*",
          "elasticloadbalancing:*"
        ]
        Resource = "*"
      },
      # EKS 관련
      {
        Effect = "Allow"
        Action = [
          "eks:*"
        ]
        Resource = "*"
      },
      # IAM 관련 (제한적)
      {
        Effect = "Allow"
        Action = [
          "iam:CreateRole",
          "iam:DeleteRole",
          "iam:GetRole",
          "iam:PassRole",
          "iam:AttachRolePolicy",
          "iam:DetachRolePolicy",
          "iam:CreatePolicy",
          "iam:DeletePolicy",
          "iam:GetPolicy",
          "iam:ListAttachedRolePolicies",
          "iam:CreateOpenIDConnectProvider",
          "iam:DeleteOpenIDConnectProvider",
          "iam:GetOpenIDConnectProvider"
        ]
        Resource = "*"
      },
      # S3 Backend
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:PutObject"
        ]
        Resource = [
          "arn:aws:s3:::plydevops-infra-tf-*",
          "arn:aws:s3:::plydevops-infra-tf-*/*"
        ]
      },
      # DynamoDB Lock
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem"
        ]
        Resource = "arn:aws:dynamodb:*:*:table/plydevops-terraform-state-lock-*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "github_actions" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.terraform_deployment.arn
}