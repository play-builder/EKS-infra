#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
chart="${SIGSTORE_CHART_ARCHIVE:-/tmp/gitops-policy-controller-0.10.5.tgz}"
[[ "$(shasum -a 256 "$chart" | awk '{print $1}')" == d1c243d566ef11c7e206cc9f6a1187f9e4291325d011d8fc432f50632296336c ]]
terraform -chdir="$root/modules/addons/sigstore-policy-controller" test -filter=tests/prerequisites.tftest.hcl -json -verbose |
 jq -r 'select(.type=="test_state") | .test_state.root_module.resources[] | select(.address=="helm_release.policy_controller") | .values.values[0]' |
 helm template policy-controller "$chart" --namespace cosign-system --include-crds -f - |
 "${ENTERPRISE_PYTHON:-python3}" -c '
import sys,yaml
docs=[d for d in yaml.safe_load_all(sys.stdin) if d]
assert not any(d["kind"] in ["ClusterImagePolicy","TrustRoot"] for d in docs)
crds={d["metadata"]["name"]:d for d in docs if d["kind"]=="CustomResourceDefinition"}
for n,c in crds.items():
 vs=c["spec"]["versions"]
 assert [v["name"] for v in vs if v["storage"]]==["v1alpha1"]
 if n.startswith("clusterimagepolicies"):assert {v["name"] for v in vs if v["served"]}=={"v1alpha1","v1beta1"}
for d in docs:
 if d["kind"]=="Deployment":
  assert d["spec"]["replicas"]==2
 if d["kind"] in ["Deployment","Job"]:
  for c in d["spec"]["template"]["spec"]["containers"]:assert "@sha256:" in c["image"],c["image"]
print("PASS: actual Sigstore Helm render pins/CRDs/prerequisites only")
'
