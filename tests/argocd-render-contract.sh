#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
chart="${ARGOCD_CHART_ARCHIVE:-/tmp/gitops-argo-cd-10.4.3.tgz}"
[[ "$(shasum -a 256 "$chart" | awk '{print $1}')" == a2cf167748f21a5a456d7070fcd6ab786c4f924b36a3aa497878e0c9b960bbab ]]
terraform -chdir="$root/modules/addons/argocd-ha" test -filter=tests/ha-sso.tftest.hcl -json -verbose |
 jq -r 'select(.type=="test_state") | .test_state.root_module.resources[] | select(.address=="helm_release.argocd") | .values.values[0]' |
 helm template argocd "$chart" --namespace argocd -f - |
 "${ENTERPRISE_PYTHON:-python3}" -c '
import sys,yaml
docs=list(yaml.safe_load_all(sys.stdin))
byname={d["metadata"]["name"]:d for d in docs if d and d["kind"] in ["Deployment","StatefulSet"]}
for n in ["argocd-server","argocd-repo-server","argocd-application-controller","argocd-applicationset-controller"]:
 d=byname[n];assert d["spec"]["replicas"]==2,n
 assert d["spec"]["template"]["spec"]["topologySpreadConstraints"],n
pdb=[d for d in docs if d and d["kind"]=="PodDisruptionBudget"]
assert len(pdb)>=4
assert all(d["spec"].get("maxUnavailable",1)<=1 for d in pdb)
assert not any(d and d["kind"]=="Secret" and d["metadata"]["name"] in ["argocd-oidc","argocd-notifications-secret","argocd-repository-credentials"] for d in docs)
cm=next(d for d in docs if d and d["kind"]=="ConfigMap" and d["metadata"]["name"]=="argocd-notifications-cm")
assert yaml.safe_load(cm["data"]["service.pagerdutyv2"])["serviceKeys"]["platform-prod"]=="$pagerduty-integration-key"
assert all("trigger."+k in cm["data"] for k in ["on-sync-failed","on-health-degraded","on-sync-status-unknown","on-deployed"])
print("PASS: Terraform-produced Argo HA Helm render")
'

chart=${ROLLOUTS_CHART_ARCHIVE:-/tmp/mini-commerce-locked-charts/argo-rollouts-2.42.0.tgz}
[[ $(shasum -a 256 "$chart" | awk '{print $1}') == d3a4ff76978290eca71f95125281c7c90b1f058a809574d39502a26143865bda ]]
helm template argo-rollouts "$chart" --namespace argo-rollouts --set providerRBAC.enabled=true --set providerRBAC.providers.istio=true --set providerRBAC.providers.gatewayAPI=false |
ruby -ryaml -e 'objects=YAML.load_stream(STDIN.read).compact; role=objects.find{|d|d["kind"]=="ClusterRole" && d["metadata"]["name"]=="argo-rollouts"}; rules=role.fetch("rules"); istio=rules.select{|r|r["apiGroups"]==["networking.istio.io"]}; abort "native Istio RBAC" unless istio.size==1 && istio[0]["resources"].sort==%w[destinationrules virtualservices] && istio[0]["verbs"].sort==%w[get list patch update watch]; abort "legacy Gateway API RBAC" if rules.any?{|r|r["apiGroups"].include?("gateway.networking.k8s.io")}'
echo 'PASS: native Rollouts Istio provider and pinned chart RBAC'
