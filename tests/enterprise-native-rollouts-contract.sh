#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
for environment in dev prod; do
  terraform -chdir="$root/environments/$environment/04-workloads/argocd" test -filter=tests/native-rollouts.tftest.hcl -no-color
done
chart=${ROLLOUTS_CHART_ARCHIVE:-/tmp/mini-commerce-locked-charts/argo-rollouts-2.42.0.tgz}
[[ $(shasum -a 256 "$chart" | awk '{print $1}') == d3a4ff76978290eca71f95125281c7c90b1f058a809574d39502a26143865bda ]]
helm template argo-rollouts "$chart" --namespace argo-rollouts --set providerRBAC.enabled=true --set providerRBAC.providers.istio=true --set providerRBAC.providers.gatewayAPI=false |
ruby -ryaml -e 'objects=YAML.load_stream(STDIN.read).compact; role=objects.find{|d|d["kind"]=="ClusterRole" && d["metadata"]["name"]=="argo-rollouts"}; rules=role.fetch("rules"); istio=rules.select{|r|r["apiGroups"]==["networking.istio.io"]}; abort "native Istio RBAC" unless istio.size==1 && istio[0]["resources"].sort==%w[destinationrules virtualservices] && istio[0]["verbs"].sort==%w[get list patch update watch]; abort "legacy Gateway API RBAC" if rules.any?{|r|r["apiGroups"].include?("gateway.networking.k8s.io")}'
echo 'PASS: native Rollouts Istio provider and pinned chart RBAC'
