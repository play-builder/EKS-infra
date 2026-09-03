#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"

jq '
  .resources += [
    {kind:"PersistentVolumeClaim",id:"app-dev/data",environment:"dev",classification:"source-pvc",owner:"course",managedBy:"terraform",billable:true,decision:"RETAIN",reason:"recovery evidence",followUpAction:"delete after approval"},
    {kind:"VolumeSnapshot",id:"app-dev/data-snapshot",environment:"dev",classification:"source-snapshot",owner:"course",managedBy:"terraform",billable:false,decision:"RETAIN",reason:"recovery evidence",followUpAction:"delete after approval"},
    {kind:"VolumeSnapshotContent",id:"data-content",environment:"dev",classification:"source-snapshot-content",owner:"course",managedBy:"terraform",billable:false,decision:"RETAIN",reason:"recovery evidence",followUpAction:"delete after approval"},
    {kind:"Namespace",id:"app-dev",environment:"dev",classification:"application-namespace",owner:"course",managedBy:"terraform",billable:false,decision:"RETAIN",reason:"namespace cleanup review",followUpAction:"delete after approval"}
  ] | .resources |= sort_by(.kind,.id)
' "$root/tests/fixtures/cleanup-ownership-valid.json" >"$tmp_dir/inventory.json"
provider_sha=$(jq -cS '[.resources[] | select(.kind == "SecretsManagerSecret")] | sort_by(.environment,.id)' \
  "$tmp_dir/inventory.json" | shasum -a 256 | awk '{print $1}')
jq --arg provider_sha "$provider_sha" '
  .retained = [
    {environment:"dev",namespace:"app-dev",kind:"PersistentVolumeClaim",name:"data",uid:"pvc-uid",classification:"source-pvc",requiresExplicitDeletion:true},
    {environment:"dev",namespace:"app-dev",kind:"VolumeSnapshot",name:"data-snapshot",uid:"snapshot-uid",classification:"source-snapshot",requiresExplicitDeletion:true},
    {environment:"dev",namespace:"",kind:"VolumeSnapshotContent",name:"data-content",uid:"content-uid",classification:"source-snapshot-content",requiresExplicitDeletion:true},
    {environment:"dev",namespace:"",kind:"Namespace",name:"app-dev",uid:"namespace-uid",classification:"application-namespace",requiresExplicitDeletion:true}
  ] | .providerSecrets.inventorySha256 = $provider_sha
' "$root/tests/fixtures/cleanup-gitops-removal-valid.json" >"$tmp_dir/removal.json"

cat >"$tmp_dir/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$FAKE_KUBECTL_LOG"
context=''
for arg in "$@"; do
  [[ "$arg" == course-dev || "$arg" == course-prod ]] && context=$arg
done
if [[ "$*" == *'get persistentvolumeclaims '* ]]; then
  if [[ "$context" == course-dev && "${FAKE_EXTRA:-false}" == true ]]; then
    printf '%s\n' '{"items":[{"kind":"PersistentVolumeClaim","metadata":{"namespace":"app-dev","name":"data","uid":"pvc-uid"}},{"kind":"PersistentVolumeClaim","metadata":{"namespace":"app-dev","name":"unexpected","uid":"unexpected-uid"}}]}'
  elif [[ "$context" == course-dev ]]; then
    printf '%s\n' '{"items":[{"kind":"PersistentVolumeClaim","metadata":{"namespace":"app-dev","name":"data","uid":"pvc-uid"}}]}'
  else
    printf '%s\n' '{"items":[]}'
  fi
elif [[ "$*" == *'get volumesnapshots.snapshot.storage.k8s.io '* ]]; then
  [[ "$context" == course-dev ]] && printf '%s\n' '{"items":[{"kind":"VolumeSnapshot","metadata":{"namespace":"app-dev","name":"data-snapshot","uid":"snapshot-uid"}}]}' || printf '%s\n' '{"items":[]}'
elif [[ "$*" == *'get volumesnapshotcontents.snapshot.storage.k8s.io '* ]]; then
  [[ "$context" == course-dev ]] && printf '%s\n' '{"items":[{"kind":"VolumeSnapshotContent","metadata":{"name":"data-content","uid":"content-uid"}}]}' || printf '%s\n' '{"items":[]}'
elif [[ "$*" == *'get podchaos.chaos-mesh.org,networkchaos.chaos-mesh.org '* ]]; then
  [[ "$context" == course-dev && "${FAKE_CHAOS:-false}" == true ]] && printf '%s\n' '{"items":[{"kind":"PodChaos","metadata":{"namespace":"app-dev","name":"active-fault"}}]}' || printf '%s\n' '{"items":[]}'
elif [[ "$*" == *'get namespaces '* ]]; then
  [[ "$context" == course-dev ]] && printf '%s\n' '{"items":[{"kind":"Namespace","metadata":{"name":"app-dev","uid":"namespace-uid"}}]}' || printf '%s\n' '{"items":[]}'
else
  printf '%s\n' '{"items":[]}'
fi
EOF
chmod +x "$tmp_dir/bin/kubectl"

FAKE_KUBECTL_LOG="$tmp_dir/kubectl.log" COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 AWS_REGION=ap-northeast-2 \
  bash "$root/scripts/kubernetes-pre-destroy-scan.sh" \
    --inventory "$tmp_dir/inventory.json" --gitops-removal "$tmp_dir/removal.json" \
    --dev-context course-dev --prod-context course-prod --output "$tmp_dir/pre-destroy.json"

grep -Fq 'get volumesnapshotcontents.snapshot.storage.k8s.io' "$tmp_dir/kubectl.log"

jq -e '[.retainedStorage[] | .kind] | sort == ["Namespace","PersistentVolumeClaim","VolumeSnapshot","VolumeSnapshotContent"]' \
  "$tmp_dir/pre-destroy.json" >/dev/null

set +e
FAKE_EXTRA=true FAKE_KUBECTL_LOG="$tmp_dir/kubectl.log" COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 AWS_REGION=ap-northeast-2 \
  bash "$root/scripts/kubernetes-pre-destroy-scan.sh" \
    --inventory "$tmp_dir/inventory.json" --gitops-removal "$tmp_dir/removal.json" \
    --dev-context course-dev --prod-context course-prod --output "$tmp_dir/pre-destroy-extra.json" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || {
  echo 'expected active retained PVC to fail closed' >&2
  exit 1
}

set +e
FAKE_CHAOS=true FAKE_KUBECTL_LOG="$tmp_dir/kubectl.log" COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 AWS_REGION=ap-northeast-2 \
  bash "$root/scripts/kubernetes-pre-destroy-scan.sh" \
    --inventory "$tmp_dir/inventory.json" --gitops-removal "$tmp_dir/removal.json" \
    --dev-context course-dev --prod-context course-prod --output "$tmp_dir/pre-destroy-chaos.json" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || {
  echo 'expected active Chaos Mesh resource to fail closed' >&2
  exit 1
}

echo 'PASS: pre-destroy retained storage is complete and kind-aware'
