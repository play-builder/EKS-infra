locals {
  oidc_provider = replace(aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")
}

data "aws_partition" "current" {}

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.cluster_log_retention_in_days

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-logs"
    }
  )
}

resource "aws_iam_role" "cluster" {
  name = "${var.name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(
    var.tags,
    {
      Name = "${var.name}-eks-cluster-role"
    }
  )
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSVPCResourceController" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.cluster.name
}

resource "aws_eks_cluster" "cluster" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids = concat(
      var.public_subnet_ids,
      var.private_subnet_ids
    )

    endpoint_private_access = var.cluster_endpoint_private_access
    endpoint_public_access  = var.cluster_endpoint_public_access
    public_access_cidrs     = var.cluster_endpoint_public_access_cidrs
  }

  kubernetes_network_config {
    service_ipv4_cidr = var.cluster_service_ipv4_cidr
  }

  enabled_cluster_log_types = var.cluster_enabled_log_types

  tags = merge(
    var.tags,
    {
      Name = var.cluster_name
    }
  )

  depends_on = [
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.cluster_AmazonEKSVPCResourceController,
    aws_cloudwatch_log_group.cluster,
  ]
}
resource "aws_iam_openid_connect_provider" "cluster" {
  client_id_list = ["sts.amazonaws.com"]
  thumbprint_list = []
  url            = aws_eks_cluster.cluster.identity[0].oidc[0].issuer

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-oidc-provider"
    }
  )
}

# modules/eks/cluster/main.tf — Append at the end

# Enable Access Entry API for EKS authentication
# This replaces the deprecated aws-auth ConfigMap approach
resource "aws_eks_access_entry" "cluster_creator" {
  count = var.enable_cluster_creator_access ? 1 : 0

  cluster_name  = aws_eks_cluster.cluster.name
  principal_arn = var.cluster_creator_arn
  type          = "STANDARD"

  depends_on = [aws_eks_cluster.cluster]
}

resource "aws_eks_access_policy_association" "cluster_creator" {
  count = var.enable_cluster_creator_access ? 1 : 0

  cluster_name  = aws_eks_cluster.cluster.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = var.cluster_creator_arn

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.cluster_creator]
}

