output "sigstore_controller" {
  value = {
    namespace           = "cosign-system"
    chartVersion        = "0.10.5"
    appVersion          = "0.13.1"
    chartDigest         = "sha256:bd825655f80a062a23e71725cb33118566ff6a90daf97a1ce17a52a4bc6e010d"
    controllerImage     = "ghcr.io/sigstore/policy-controller/policy-controller@sha256:0bcd60beb93f4427c29cf3a669743caf58490e98ded4380c33c09f092734a6ab"
    cipServedVersions   = ["v1alpha1", "v1beta1"]
    cipStorageVersion   = "v1alpha1"
    trustrootApiVersion = "v1alpha1"
    readyReplicaMinimum = var.replicas
    policyOwner         = "argocd-gitops"
  }
}
output "rendered_crd_hash" { value = filesha256("${path.module}/../../../vendor/sigstore-policy-controller/0.10.5/crds.yaml") }
