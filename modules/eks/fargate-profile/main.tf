# 1. Fargate Pod Execution Role
resource "aws_iam_role" "fargate_pod_execution" {
  name = "${var.cluster_name}-${var.fargate_profile_name}-role"
  tags = var.common_tags
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "eks-fargate-pods.amazonaws.com"
      }
    }]
  })
}

# 2. Attach required policy
resource "aws_iam_role_policy_attachment" "fargate_pod_execution" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSFargatePodExecutionRolePolicy"
  role       = aws_iam_role.fargate_pod_execution.name
}

# 3. Fargate Profile Resource
resource "aws_eks_fargate_profile" "fargate" {
  cluster_name           = var.cluster_name
  fargate_profile_name   = var.fargate_profile_name
  pod_execution_role_arn = aws_iam_role.fargate_pod_execution.arn
  subnet_ids             = var.subnet_ids

  dynamic "selector" {
    for_each = var.selectors
    content {
      namespace = selector.value.namespace
      labels    = selector.value.labels
    }
  }

  tags = var.common_tags
}