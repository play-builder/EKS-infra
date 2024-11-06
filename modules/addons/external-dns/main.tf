# =============================================================================
# 1. IAM Policy & Role (IRSA)
# =============================================================================
# ExternalDNS 권한 정의 (Scope Down 적용)
module "irsa_role" {
  source = "../../iam/irsa"

  name                 = "${var.cluster_name}-external-dns"
  namespace            = var.namespace
  service_account_name = "external-dns"

  oidc_provider_arn = var.oidc_provider_arn
  oidc_provider     = var.oidc_provider

  iam_policy_statements = [
    {
      sid     = "ChangeResourceRecordSets"
      effect  = "Allow"
      actions = ["route53:ChangeResourceRecordSets"]
      # [보안] 특정 Hosted Zone만 수정 가능하도록 제한
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

# =============================================================================
# 2. Helm Release (ExternalDNS 배포)
# =============================================================================
resource "helm_release" "external_dns" {
  name       = "external-dns"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = var.chart_version
  namespace  = var.namespace # kube-system

  # ---------------------------------------------------------------------------
  # Helm Values (Modern Approach using yamlencode)
  # ---------------------------------------------------------------------------
  values = [
    yamlencode({
      # 이미지 설정
      image = {
        repository = "registry.k8s.io/external-dns/external-dns"
      }

      # 서비스 계정 설정 (IRSA 연결)
      serviceAccount = {
        create = true
        name   = "external-dns"
        annotations = {
          # 점(.)이 들어간 키도 별도 이스케이프 없이 깔끔하게 작성 가능
          "eks.amazonaws.com/role-arn" = module.irsa_role.iam_role_arn
        }
      }

      # Provider 설정 (AWS)
      provider = "aws"

      # AWS 세부 설정
      aws = {
        zoneType = "public"
        region   = var.aws_region
      }

      # [보안] Domain Filter: 관리할 도메인 리스트
      # set 방식보다 훨씬 직관적임 (리스트 그대로 전달)
      domainFilters = var.domain_filters

      # [충돌 방지] TXT Owner ID: 클러스터 식별자
      txtOwnerId = var.cluster_name

      # [운영] Sync Policy: 리소스 삭제 시 DNS 레코드 자동 정리
      policy = "sync" #[PROD] => upsert-only

      # (선택 사항) 로그 레벨 조정
      logLevel = "info"
    })
  ]
}