#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

jq '
  .resources |= map(if .kind == "SecretsManagerSecret" then .decision = "RETAIN" | .owner = "course" else . end) |
  .resources += [
    {kind:"PersistentVolumeClaim",id:"app-dev/data",environment:"dev",classification:"source-pvc",owner:"course",managedBy:"terraform",billable:true,decision:"RETAIN",reason:"recovery evidence",followUpAction:"delete after approval"},
    {kind:"VolumeSnapshot",id:"app-dev/data-snapshot",environment:"dev",classification:"source-snapshot",owner:"course",managedBy:"terraform",billable:false,decision:"RETAIN",reason:"recovery evidence",followUpAction:"delete after approval"},
    {kind:"Namespace",id:"app-dev",environment:"dev",classification:"application-namespace",owner:"course",managedBy:"terraform",billable:false,decision:"RETAIN",reason:"namespace cleanup review",followUpAction:"delete after approval"}
  ] |
  .resources |= sort_by(.kind,.id)
' "$root/tests/fixtures/cleanup-ownership-valid.json" >"$tmp_dir/inventory.json"

provider_id=$(jq -r '.resources[] | select(.kind == "SecretsManagerSecret") | .id' "$tmp_dir/inventory.json")
provider_classification=$(jq -r '.resources[] | select(.kind == "SecretsManagerSecret") | .classification' "$tmp_dir/inventory.json")
provider_sha=$(jq -cS '[.resources[] | select(.kind == "SecretsManagerSecret")] | sort_by(.environment,.id)' \
  "$tmp_dir/inventory.json" | shasum -a 256 | awk '{print $1}')
jq --arg provider_id "$provider_id" --arg provider_classification "$provider_classification" --arg provider_sha "$provider_sha" '
  .retained = [
    {environment:"dev",namespace:"app-dev",kind:"PersistentVolumeClaim",name:"data",uid:"pvc-uid",classification:"source-pvc",requiresExplicitDeletion:true},
    {environment:"dev",namespace:"app-dev",kind:"VolumeSnapshot",name:"data-snapshot",uid:"snapshot-uid",classification:"source-snapshot",requiresExplicitDeletion:true},
    {environment:"dev",namespace:"",kind:"Namespace",name:"app-dev",uid:"namespace-uid",classification:"application-namespace",requiresExplicitDeletion:true},
    {environment:"shared",namespace:"",kind:"SecretsManagerSecret",name:$provider_id,uid:"provider-uid",classification:$provider_classification,requiresExplicitDeletion:true}
  ] | .providerSecrets.inventorySha256 = $provider_sha
' "$root/tests/fixtures/cleanup-gitops-removal-valid.json" >"$tmp_dir/removal.json"

export COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 AWS_REGION=ap-northeast-2
source "$root/scripts/lib/evidence-common.sh"
source "$root/scripts/lib/cleanup-evidence.sh"

cleanup_validate_removal "$tmp_dir/inventory.json" "$tmp_dir/removal.json"

assert_rejected() {
  local inventory=$1 removal=$2 status
  set +e
  (cleanup_validate_removal "$inventory" "$removal") >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || {
    echo "expected retained identity rejection: $removal" >&2
    exit 1
  }
}

jq '.retained[0].kind="VolumeSnapshot"' "$tmp_dir/removal.json" >"$tmp_dir/wrong-kind.json"
assert_rejected "$tmp_dir/inventory.json" "$tmp_dir/wrong-kind.json"

jq '.resources |= map(if .kind == "PersistentVolumeClaim" then .id="app-dev/data-pvc-uid" else . end)' \
  "$tmp_dir/inventory.json" >"$tmp_dir/suffix-collision-inventory.json"
assert_rejected "$tmp_dir/suffix-collision-inventory.json" "$tmp_dir/removal.json"

jq 'del(.retained[2])' "$tmp_dir/removal.json" >"$tmp_dir/omitted-retained.json"
assert_rejected "$tmp_dir/inventory.json" "$tmp_dir/omitted-retained.json"

echo 'PASS: retained cleanup identities are complete, typed, and exact'
