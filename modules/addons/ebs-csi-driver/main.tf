# ============================================
# EBS CSI Driver Add-on Module
# ============================================

# ============================================
# Data Source: Latest EBS CSI IAM Policy from GitHub
# ============================================
data "http" "ebs_csi_iam_policy" {
  count = var.use_aws_managed_policy ? 0 : 1

  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-ebs-csi-driver/master/docs/example-iam-policy.json"

  request_headers = {
    Accept = "application/json"
  }
}

# ============================================
# IAM Policy for EBS CSI Driver
# ============================================
resource "aws_iam_policy" "ebs_csi" {
  count = var.use_aws_managed_policy ? 0 : 1

  name        = "${var.name}-ebs-csi-driver-policy"
  path        = "/"
  description = "IAM Policy for EBS CSI Driver on ${var.eks_cluster_name}"
  policy      = data.http.ebs_csi_iam_policy[0].response_body

  tags = merge(
    var.tags,
    {
      Name = "${var.name}-ebs-csi-driver-policy"
    }
  )
}

# ============================================
# IAM Role for EBS CSI Driver (IRSA)
# ============================================
resource "aws_iam_role" "ebs_csi" {
  name = "${var.name}-ebs-csi-driver-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRoleWithWebIdentity"
        Principal = {
          Federated = var.oidc_provider_arn
        }
        Condition = {
          StringEquals = {
            "${var.oidc_provider}:sub" = "system:serviceaccount:${var.namespace}:${var.service_account_name}"
            "${var.oidc_provider}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = merge(
    var.tags,
    {
      Name = "${var.name}-ebs-csi-driver-role"
    }
  )
}

# ============================================
# Attach IAM Policy to Role
# ============================================
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  policy_arn = var.use_aws_managed_policy ? var.aws_managed_policy_arn : aws_iam_policy.ebs_csi[0].arn
  role       = aws_iam_role.ebs_csi.name
}

# ============================================
# EKS Add-on: EBS CSI Driver
# ============================================
resource "aws_eks_addon" "ebs_csi" {
  depends_on = [aws_iam_role_policy_attachment.ebs_csi]

  cluster_name                = var.eks_cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = var.addon_version != "" ? var.addon_version : null
  service_account_role_arn    = aws_iam_role.ebs_csi.arn
  resolve_conflicts_on_create = var.resolve_conflicts_on_create

  tags = merge(
    var.tags,
    {
      Name = "${var.name}-ebs-csi-driver-addon"
    }
  )
}