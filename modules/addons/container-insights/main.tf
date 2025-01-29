resource "kubernetes_namespace_v1" "amazon_cloudwatch" {
  metadata {
    name = "amazon-cloudwatch"
    labels = {
      name = "amazon-cloudwatch"
    }
  }
}

module "irsa_role" {
  source = "../../iam/irsa"

  name                 = "${var.eks_cluster_name}-container-insights"
  namespace            = "amazon-cloudwatch"
  service_account_name = "cloudwatch-agent"

  oidc_provider_arn = var.oidc_provider_arn
  oidc_provider     = var.oidc_provider

  iam_policy_statements = [
    {
      sid    = "CloudWatchLogs"
      effect = "Allow"
      actions = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      resources = ["*"]
    },
    {
      sid    = "CloudWatchMetrics"
      effect = "Allow"
      actions = [
        "cloudwatch:PutMetricData"
      ]
      resources = ["*"]
    },
    {
      sid    = "EC2Describe"
      effect = "Allow"
      actions = [
        "ec2:DescribeInstances",
        "ec2:DescribeTags",
        "ec2:DescribeVolumes"
      ]
      resources = ["*"]
    }
  ]

  tags = var.tags
}

resource "helm_release" "cloudwatch_agent" {
  name       = "aws-cloudwatch-metrics"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-cloudwatch-metrics"
  version    = var.cloudwatch_agent_chart_version
  namespace  = kubernetes_namespace_v1.amazon_cloudwatch.metadata[0].name

  values = [
    yamlencode({
      clusterName = var.eks_cluster_name

      serviceAccount = {
        create = true
        name   = "cloudwatch-agent"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.irsa_role.iam_role_arn
        }
      }

      resources = {
        requests = {
          cpu    = "50m"
          memory = "50Mi"
        }
        limits = {
          cpu    = "100m"
          memory = "100Mi"
        }
      }

      tolerations = [
        {
          operator = "Exists"
        }
      ]
    })
  ]

  depends_on = [
    kubernetes_namespace_v1.amazon_cloudwatch,
    module.irsa_role
  ]
}

resource "helm_release" "fluent_bit" {
  name       = "aws-for-fluent-bit"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-for-fluent-bit"
  version    = var.fluent_bit_chart_version
  namespace  = kubernetes_namespace_v1.amazon_cloudwatch.metadata[0].name

  values = [
    yamlencode({
      cloudWatchLogs = {
        enabled         = true
        region          = var.aws_region
        logGroupName    = "/aws/containerinsights/${var.eks_cluster_name}/application"
        autoCreateGroup = true
      }

      serviceAccount = {
        create = true
        name   = "fluent-bit"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.irsa_role.iam_role_arn
        }
      }

      resources = {
        requests = {
          cpu    = "50m"
          memory = "50Mi"
        }
        limits = {
          cpu    = "100m"
          memory = "100Mi"
        }
      }

      tolerations = [
        {
          operator = "Exists"
        }
      ]
    })
  ]

  depends_on = [
    kubernetes_namespace_v1.amazon_cloudwatch,
    module.irsa_role
  ]
}
