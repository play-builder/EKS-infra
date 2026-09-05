locals {
  owned_tags = merge(var.tags, { ManagedBy = "Terraform" })
  groups = {
    application = var.application_retention_days
    performance = var.performance_retention_days
  }
  group_arns       = { for kind in keys(local.groups) : kind => "arn:aws:logs:${var.aws_region}:${var.account_id}:log-group:/aws/containerinsights/${var.eks_cluster_name}/${kind}" }
  service_accounts = { cloudwatch_agent = "cloudwatch-agent", fluent_bit = "fluent-bit" }
  trust_policies = { for key, sa in local.service_accounts : key => jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = var.oidc_provider_arn }
      Condition = { StringEquals = {
        "${var.oidc_provider}:sub" = "system:serviceaccount:amazon-cloudwatch:${sa}"
        "${var.oidc_provider}:aud" = "sts.amazonaws.com"
      } }
    }]
  }) }
  log_statements = { for kind, arn in local.group_arns : kind => [
    {
      Sid      = "ExactLogStreams"
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = ["${arn}:log-stream:*"]
    },
    {
      Sid      = "DescribeExactGroupStreams"
      Effect   = "Allow"
      Action   = ["logs:DescribeLogStreams"]
      Resource = ["${arn}:*"]
    },
    {
      Sid      = "EncryptedLogsViaRegionalService"
      Effect   = "Allow"
      Action   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncryptFrom", "kms:ReEncryptTo", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext", "kms:DescribeKey"]
      Resource = [var.kms_key_arn]
      Condition = {
        StringEquals = { "kms:ViaService" = "logs.${var.aws_region}.amazonaws.com" }
        ArnEquals    = { "kms:EncryptionContext:aws:logs:arn" = arn }
      }
    }
  ] }
}
resource "kubernetes_namespace_v1" "amazon_cloudwatch" {
  metadata {
    name   = "amazon-cloudwatch"
    labels = { name = "amazon-cloudwatch" }
  }
}
resource "aws_cloudwatch_log_group" "this" {
  for_each          = local.groups
  name              = "/aws/containerinsights/${var.eks_cluster_name}/${each.key}"
  retention_in_days = each.value
  kms_key_id        = var.kms_key_arn
  tags              = local.owned_tags
}
# Preserve the existing AWS role/policy names and migrate only their Terraform addresses.
moved {
  from = module.irsa_role.aws_iam_role.this
  to   = aws_iam_role.cloudwatch_agent
}
moved {
  from = module.irsa_role.aws_iam_policy.this[0]
  to   = aws_iam_policy.cloudwatch_agent
}
moved {
  from = module.irsa_role.aws_iam_role_policy_attachment.this[0]
  to   = aws_iam_role_policy_attachment.cloudwatch_agent
}
resource "aws_iam_role" "cloudwatch_agent" {
  name               = "${var.eks_cluster_name}-container-insights-role"
  assume_role_policy = local.trust_policies.cloudwatch_agent
  tags               = local.owned_tags
}
resource "aws_iam_policy" "cloudwatch_agent" {
  name        = "${var.eks_cluster_name}-container-insights-policy"
  description = "IAM Policy for ${var.eks_cluster_name}-container-insights"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.log_statements.performance, [
      {
        Sid       = "ContainerInsightsMetrics"
        Effect    = "Allow"
        Action    = ["cloudwatch:PutMetricData"]
        Resource  = ["*"]
        Condition = { StringEquals = { "cloudwatch:namespace" = "ContainerInsights" } }
      },
      {
        Sid      = "EC2Metadata"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "ec2:DescribeTags", "ec2:DescribeVolumes"]
        Resource = ["*"]
      }
    ])
  })
  tags = local.owned_tags
}
resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.cloudwatch_agent.name
  policy_arn = aws_iam_policy.cloudwatch_agent.arn
}
resource "aws_iam_role" "fluent_bit" {
  name               = "${var.eks_cluster_name}-fluent-bit-role"
  assume_role_policy = local.trust_policies.fluent_bit
  tags               = local.owned_tags
}
resource "aws_iam_policy" "fluent_bit" {
  name   = "${var.eks_cluster_name}-fluent-bit-policy"
  policy = jsonencode({ Version = "2012-10-17", Statement = local.log_statements.application })
  tags   = local.owned_tags
}
resource "aws_iam_role_policy_attachment" "fluent_bit" {
  role       = aws_iam_role.fluent_bit.name
  policy_arn = aws_iam_policy.fluent_bit.arn
}
resource "helm_release" "cloudwatch_agent" {
  name       = "aws-cloudwatch-metrics"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-cloudwatch-metrics"
  version    = var.cloudwatch_agent_chart_version
  namespace  = kubernetes_namespace_v1.amazon_cloudwatch.metadata[0].name
  values = [yamlencode({
    clusterName = var.eks_cluster_name
    statsd      = { enabled = false }
    serviceAccount = {
      create      = true
      name        = "cloudwatch-agent"
      annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.cloudwatch_agent.arn }
    }
    resources = {
      requests = { cpu = "50m", memory = "50Mi" }
      limits   = { cpu = "100m", memory = "100Mi" }
    }
    tolerations = [{ operator = "Exists" }]
  })]
  depends_on = [aws_cloudwatch_log_group.this, aws_iam_role_policy_attachment.cloudwatch_agent]
}
resource "helm_release" "fluent_bit" {
  name       = "aws-for-fluent-bit"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-for-fluent-bit"
  version    = var.fluent_bit_chart_version
  namespace  = kubernetes_namespace_v1.amazon_cloudwatch.metadata[0].name
  values = [yamlencode({
    cloudWatch = { enabled = false }
    cloudWatchLogs = {
      enabled         = true
      region          = var.aws_region
      logGroupName    = aws_cloudwatch_log_group.this["application"].name
      autoCreateGroup = false
    }
    serviceAccount = {
      create      = true
      name        = "fluent-bit"
      annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.fluent_bit.arn }
    }
    resources = {
      requests = { cpu = "50m", memory = "50Mi" }
      limits   = { cpu = "100m", memory = "100Mi" }
    }
    tolerations = [{ operator = "Exists" }]
  })]
  depends_on = [aws_cloudwatch_log_group.this, aws_iam_role_policy_attachment.fluent_bit]
}
data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
