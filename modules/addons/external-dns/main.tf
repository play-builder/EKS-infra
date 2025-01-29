module "irsa_role" {
  source = "../../iam/irsa"

  name                 = "${var.cluster_name}-external-dns"
  namespace            = var.namespace
  service_account_name = "external-dns"

  oidc_provider_arn = var.oidc_provider_arn
  oidc_provider     = var.oidc_provider

  iam_policy_statements = [
    {
      sid       = "ChangeResourceRecordSets"
      effect    = "Allow"
      actions   = ["route53:ChangeResourceRecordSets"]
      resources = ["arn:aws:route53:::hostedzone/${var.hosted_zone_id}"]
    },
    {
      sid       = "ListResourceRecordSets"
      effect    = "Allow"
      actions   = ["route53:ListHostedZones", "route53:ListResourceRecordSets"]
      resources = ["*"]
    }
  ]

  tags = var.tags
}

resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = var.chart_version
  namespace  = var.namespace

  values = [
    yamlencode({
      image = {
        repository = "registry.k8s.io/external-dns/external-dns"
      }

      serviceAccount = {
        create = true
        name   = "external-dns"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.irsa_role.iam_role_arn
        }
      }

      provider = "aws"

      aws = {
        zoneType = "public"
        region   = var.aws_region
      }

      domainFilters = var.domain_filters

      txtOwnerId = var.cluster_name

      policy = "sync"

      logLevel = "info"
    })
  ]
}
