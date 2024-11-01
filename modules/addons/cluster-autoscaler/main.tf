# ============================================
# Cluster Autoscaler Module
# ============================================
# 왜 필요한가?
# - Pending 상태의 Pod가 있을 때 자동으로 노드 추가
# - 사용률 낮은 노드를 자동으로 제거하여 비용 절감
# - 현업에서 가장 중요한 Day-2 운영 도구

# ============================================
# 1. IRSA Role for Cluster Autoscaler
# ============================================
resource "aws_iam_role" "cluster_autoscaler" {
  name = "${var.cluster_name}-cluster-autoscaler"
  tags = var.common_tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRoleWithWebIdentity"
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = {
        StringEquals = {
          # [수정] var.oidc_provider 사용 (https:// 없는 형태)
          "${var.oidc_provider}:sub" = "system:serviceaccount:kube-system:cluster-autoscaler"
          "${var.oidc_provider}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# ============================================
# 2. IAM Policy for AutoScaling
# ============================================
resource "aws_iam_policy" "cluster_autoscaler" {
  name   = "${var.cluster_name}-cluster-autoscaler-policy"
  policy = data.aws_iam_policy_document.cluster_autoscaler.json
  tags   = var.common_tags
}

# ============================================
# 3. Attach Policy to Role
# ============================================
resource "aws_iam_role_policy_attachment" "cluster_autoscaler" {
  policy_arn = aws_iam_policy.cluster_autoscaler.arn
  role       = aws_iam_role.cluster_autoscaler.name
}

# ============================================
# 4. Deploy Helm Chart
# ============================================
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"
  version    = var.chart_version
  wait       = true

  values = [
    yamlencode({
      # AWS 설정
      cloudProvider = "aws"
      awsRegion     = var.aws_region

      # 클러스터 자동 검색 (Node Group 태그 기반)
      autoDiscovery = {
        clusterName = var.cluster_name
        enabled     = true
      }

      # IRSA 서비스 계정
      rbac = {
        serviceAccount = {
          create = true
          name   = "cluster-autoscaler"
          annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.cluster_autoscaler.arn
          }
        }
      }

      # 현업 권장 설정
      extraArgs = {
        # 스케일 다운 안정화
        "scale-down-delay-after-add"       = "10m"
        "scale-down-delay-after-delete"    = "10s"
        "scale-down-unneeded-time"         = "10m"
        "scale-down-utilization-threshold" = "0.5"

        # 스캔 간격
        "scan-interval" = "10s"

        # 비용 최적화
        "expander"                      = "least-waste"
        "skip-nodes-with-local-storage" = "false"
        "skip-nodes-with-system-pods"   = "true"
        "balance-similar-node-groups"   = "true"
      }

      # 리소스 제한
      resources = {
        requests = {
          cpu    = "100m"
          memory = "300Mi"
        }
        limits = {
          cpu    = "200m"
          memory = "500Mi"
        }
      }
    })
  ]

  depends_on = [aws_iam_role_policy_attachment.cluster_autoscaler]
}

# ============================================
# IAM Policy Document
# ============================================
data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    sid    = "ClusterAutoscalerDescribe"
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeTags",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:DescribeInstanceTypes",
      "eks:DescribeNodegroup"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ClusterAutoscalerModify"
    effect = "Allow"
    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "autoscaling:UpdateAutoScalingGroup"
    ]
    resources = ["*"]

    # 특정 클러스터의 ASG만 제어 (보안 강화)
    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/enabled"
      values   = ["true"]
    }
    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}"
      values   = ["owned"]
    }
  }
}