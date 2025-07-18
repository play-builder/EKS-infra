# Leave it in-case of changing iam policy
# ----------------------------
# data "http" "lbc_iam_policy" {
#   url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json"

#   request_headers = {
#     Accept = "application/json"
#   }
# }

resource "aws_iam_policy" "lbc" {
  name        = "${var.name}-AWSLoadBalancerControllerIAMPolicy"
  path        = "/"
  description = "AWS Load Balancer Controller IAM Policy"
  policy      = file("${path.module}/iam-policy.json")

  tags = merge(
    var.common_tags,
    {
      Name = "${var.name}-lbc-iam-policy"
    }
  )
}

module "irsa_role" {
  source = "../../iam/irsa"

  name = "${var.name}-lbc-iam-role"

  oidc_provider_arn = var.oidc_provider_arn
  oidc_provider     = var.oidc_provider

  namespace            = var.namespace
  service_account_name = var.service_account_name

  create_service_account = false

  iam_policy_statements = []

  tags = var.common_tags
}

resource "aws_iam_role_policy_attachment" "lbc" {
  policy_arn = aws_iam_policy.lbc.arn
  role       = module.irsa_role.iam_role_name
}

resource "helm_release" "lbc" {
  depends_on = [aws_iam_role_policy_attachment.lbc]

  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.helm_chart_version
  namespace  = var.namespace

  values = [
    yamlencode({
      clusterName  = var.eks_cluster_name
      vpcId        = var.vpc_id
      region       = var.aws_region
      replicaCount = var.replica_count

      serviceAccount = {
        create = true
        name   = var.service_account_name
        annotations = {
          "eks.amazonaws.com/role-arn" = module.irsa_role.iam_role_arn
        }
      }

      image = {
        repository = "${var.ecr_account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/amazon/aws-load-balancer-controller"
      }

      ingressClass = var.ingress_class_name
      ingressClassConfig = {
        default = var.is_default_class
      }
      createIngressClassResource = true

      enableWaf    = var.enable_waf
      enableWafv2  = var.enable_wafv2
      enableShield = var.enable_shield
    })
  ]
}

