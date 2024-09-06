# ============================================
# EKS Node Group Module - Main Configuration
# ============================================
# 용도: EKS Cluster에 독립적으로 Node Group을 생성하는 재사용 가능한 모듈
# 특징: Public/Private 서브넷 지원, Autoscaling, SSM 접근, Cluster Autoscaler 태그

# ============================================
# IAM Role for EKS Node Group
# ============================================
resource "aws_iam_role" "node_group" {
  name = "${var.name}-${var.node_group_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(
    var.common_tags,
    {
      Name = "${var.name}-${var.node_group_name}-role"
    }
  )
}

# ============================================
# IAM Role Policy Attachments
# ============================================

# Required: Worker Node Policy
resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node_group.name
}

# Required: CNI Policy
resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node_group.name
}

# Required: Container Registry Read-Only
resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node_group.name
}

# Optional: SSM Access for debugging
resource "aws_iam_role_policy_attachment" "node_AmazonSSMManagedInstanceCore" {
  count      = var.enable_ssm ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.node_group.name
}

# Optional: CloudWatch Agent for Container Insights
resource "aws_iam_role_policy_attachment" "node_CloudWatchAgentServerPolicy" {
  count      = var.enable_cloudwatch ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = aws_iam_role.node_group.name
}

# ============================================
# EKS Node Group
# ============================================
resource "aws_eks_node_group" "this" {
  cluster_name    = var.cluster_name
  node_group_name = "${var.name}-${var.node_group_name}"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = var.subnet_ids
  version         = var.cluster_version

  # Instance Configuration
  ami_type       = var.ami_type
  capacity_type  = var.capacity_type
  disk_size      = var.disk_size
  instance_types = var.instance_types

  # Scaling Configuration
  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }

  # Update Configuration
  update_config {
    max_unavailable_percentage = var.max_unavailable_percentage
  }

  # SSH Access Configuration (Optional)
  dynamic "remote_access" {
    for_each = var.ssh_key_name != "" ? [1] : []
    content {
      ec2_ssh_key               = var.ssh_key_name
      source_security_group_ids = var.ssh_source_security_group_ids
    }
  }

  # Kubernetes Labels
  labels = merge(
    var.kubernetes_labels,
    {
      NodeGroup = var.node_group_name
      Type      = var.node_group_type # public or private
    }
  )

  # Tags for Cluster Autoscaler
  tags = merge(
    var.common_tags,
    {
      Name = "${var.name}-${var.node_group_name}"
      Type = var.node_group_type
      # Cluster Autoscaler Discovery Tags
      "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
      "k8s.io/cluster-autoscaler/enabled"             = "true"
    }
  )

  # Dependencies
  depends_on = [
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
  ]

  # Lifecycle
  lifecycle {
    create_before_destroy = true
    # Cluster Autoscaler가 desired_size를 관리하므로 변경 무시
    ignore_changes = [scaling_config[0].desired_size]
  }
}