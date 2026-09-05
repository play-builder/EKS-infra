locals {
  values = {
    installCRDs = true
    webhook = {
      replicaCount        = var.replicas
      image               = { repository = "ghcr.io/sigstore/policy-controller/policy-controller", version = "sha256:0bcd60beb93f4427c29cf3a669743caf58490e98ded4380c33c09f092734a6ab" }
      failurePolicy       = "Fail"
      podDisruptionBudget = { enabled = true, minAvailable = 1 }
      resources           = { requests = { cpu = "100m", memory = "128Mi" }, limits = { cpu = "500m", memory = "512Mi" } }
      serviceAccount      = { create = true, name = "policy-controller", annotations = { "eks.amazonaws.com/role-arn" = aws_iam_role.reader.arn } }
    }
    leasescleanup = { image = { repository = "cgr.dev/chainguard/kubectl", version = "latest-dev@sha256:1e1ef597cf577885d2b1b5fa927efad03164292069bc67f20ee3c15db62e7f5d" } }
  }
}
resource "aws_iam_role" "reader" {
  name               = "${var.name}-sigstore-ecr-reader"
  tags               = var.tags
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = "sts:AssumeRoleWithWebIdentity", Principal = { Federated = var.oidc_provider_arn }, Condition = { StringEquals = { "${var.oidc_provider}:aud" = "sts.amazonaws.com", "${var.oidc_provider}:sub" = "system:serviceaccount:cosign-system:policy-controller" } } }] })
}
resource "aws_iam_role_policy" "reader" {
  role = aws_iam_role.reader.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["ecr:GetAuthorizationToken"], Resource = "*" },
    { Effect = "Allow", Action = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"], Resource = var.repository_arns }
  ] })
}
resource "helm_release" "policy_controller" {
  name             = "policy-controller"
  repository       = "oci://ghcr.io/sigstore/helm-charts"
  chart            = "policy-controller"
  version          = "0.10.5"
  namespace        = "cosign-system"
  create_namespace = true
  atomic           = true
  timeout          = 900
  values           = [yamlencode(local.values)]
}
resource "kubectl_manifest" "egress" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "NetworkPolicy"
    metadata   = { name = "policy-controller-egress", namespace = "cosign-system" }
    spec = {
      podSelector = {}
      policyTypes = ["Egress"]
      egress = [
        { to = [{ namespaceSelector = { matchLabels = { "kubernetes.io/metadata.name" = "kube-system" } }, podSelector = { matchLabels = { "k8s-app" = "kube-dns" } } }], ports = [{ protocol = "UDP", port = 53 }, { protocol = "TCP", port = 53 }] },
        { to = [for c in setunion(var.api_server_cidrs, var.https_egress_cidrs) : { ipBlock = { cidr = c } }], ports = [{ protocol = "TCP", port = 443 }] }
      ]
    }
  })
  depends_on = [helm_release.policy_controller]
}
