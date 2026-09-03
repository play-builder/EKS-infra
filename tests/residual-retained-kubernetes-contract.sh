#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/cleanup-fixture-helpers.sh"

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work/evidence"
prepare_cleanup_fixtures "$root" "$work/evidence" ap-northeast-2

kubernetes_resources=$(jq -n '[
  {kind:"Namespace",id:"app-recovery",environment:"dev",classification:"recovery-namespace",owner:"course",managedBy:"terraform",billable:false,decision:"RETAIN",reason:"recovery evidence",followUpAction:"delete after explicit approval"},
  {kind:"PersistentVolumeClaim",id:"app-dev/data-postgresql-0",environment:"dev",classification:"source-pvc",owner:"course",managedBy:"terraform",billable:true,decision:"RETAIN",reason:"recovery evidence",followUpAction:"delete after explicit approval"},
  {kind:"VolumeSnapshot",id:"app-dev/data-snapshot",environment:"dev",classification:"source-snapshot",owner:"course",managedBy:"terraform",billable:true,decision:"RETAIN",reason:"recovery evidence",followUpAction:"delete after explicit approval"},
  {kind:"VolumeSnapshotContent",id:"data-content",environment:"dev",classification:"source-snapshot-content",owner:"course",managedBy:"terraform",billable:false,decision:"RETAIN",reason:"recovery evidence",followUpAction:"delete after explicit approval"}
]')
kubernetes_decisions=$(jq -n --argjson resources "$kubernetes_resources" '[
  $resources[] | {kind,id,decision,reason,followUpAction}
]')
kubernetes_retained=$(jq -n '[
  {environment:"dev",namespace:"",kind:"Namespace",name:"app-recovery",uid:"namespace-uid",classification:"recovery-namespace",requiresExplicitDeletion:true},
  {environment:"dev",namespace:"",kind:"VolumeSnapshotContent",name:"data-content",uid:"content-uid",classification:"source-snapshot-content",requiresExplicitDeletion:true},
  {environment:"dev",namespace:"app-dev",kind:"PersistentVolumeClaim",name:"data-postgresql-0",uid:"pvc-uid",classification:"source-pvc",requiresExplicitDeletion:true},
  {environment:"dev",namespace:"app-dev",kind:"VolumeSnapshot",name:"data-snapshot",uid:"snapshot-uid",classification:"source-snapshot",requiresExplicitDeletion:true}
]')

jq --argjson extra "$kubernetes_resources" \
  '.resources += $extra | .resources |= sort_by(.kind,.id)' \
  "$work/evidence/inventory.json" >"$work/inventory.json"
mv "$work/inventory.json" "$work/evidence/inventory.json"
inventory_sha=$(raw_sha256 "$work/evidence/inventory.json")

jq --arg inventory "$inventory_sha" --argjson extra "$kubernetes_decisions" \
  '.inventorySha256=$inventory | .decisions += $extra | .decisions |= sort_by(.kind,.id)' \
  "$work/evidence/decisions.json" >"$work/decisions.json"
mv "$work/decisions.json" "$work/evidence/decisions.json"

jq --argjson retained "$kubernetes_retained" '.retained=$retained' \
  "$work/evidence/removal.json" >"$work/removal.json"
mv "$work/removal.json" "$work/evidence/removal.json"
removal_sha=$(raw_sha256 "$work/evidence/removal.json")

jq --arg removal "$removal_sha" --argjson retained "$kubernetes_retained" \
  '.gitopsRemovalSha256=$removal | .retainedStorage=[$retained[] | del(.requiresExplicitDeletion)]' \
  "$work/evidence/pre-destroy.json" >"$work/pre-destroy.json"
mv "$work/pre-destroy.json" "$work/evidence/pre-destroy.json"

: >"$work/aws.log"

common=(
  --inventory "$work/evidence/inventory.json"
  --retain-decisions "$work/evidence/decisions.json"
  --kubernetes-pre-destroy "$work/evidence/pre-destroy.json"
  --gitops-removal "$work/evidence/removal.json"
)

run_scan() {
  local output=$1
  COURSE_CHECK_BIN_DIR="$root/tests/helpers/residual-retained-bin" \
    COURSE_FAKE_AWS_LOG="$work/aws.log" AWS_PROFILE=course AWS_REGION=ap-northeast-2 \
    AWS_ACCOUNT_ID=123456789012 COURSE_ID=course-2026 \
    RESIDUAL_SCAN_ATTEMPTS=1 RESIDUAL_SCAN_DELAY_SECONDS=0 \
    bash "$root/scripts/residual-scan.sh" "${common[@]}" --output "$output"
}

: >"$work/aws.log"
set +e
output=$(PATH="$root/tests/helpers/residual-retained-bin:$PATH" COURSE_FAKE_AWS_LOG="$work/aws.log" \
  AWS_PROFILE=course AWS_REGION=ap-northeast-2 AWS_ACCOUNT_ID=123456789012 COURSE_ID=course-2026 \
  RESIDUAL_SCAN_ATTEMPTS=1 RESIDUAL_SCAN_DELAY_SECONDS=0 \
    bash "$root/scripts/residual-scan.sh" "${common[@]}" --output "$work/evidence/runtime-residual.json" 2>&1)
status=$?
set -e
if [[ "$status" -eq 0 ]] || ! grep -Fq 'NONCANONICAL_RUNTIME_OUTPUT' <<<"$output"; then
  echo 'real residual scan accepted a noncanonical output' >&2
  exit 1
fi
[[ ! -s "$work/aws.log" && ! -e "$work/evidence/runtime-residual.json" ]]

: >"$work/aws.log"
set +e
output=$(COURSE_CHECK_BIN_DIR="$root/tests/helpers/residual-retained-bin" COURSE_FAKE_AWS_LOG="$work/aws.log" \
  AWS_PROFILE=course AWS_REGION=ap-northeast-2 AWS_ACCOUNT_ID=123456789012 COURSE_ID=course-2026 \
  RESIDUAL_SCAN_ATTEMPTS=1 RESIDUAL_SCAN_DELAY_SECONDS=0 \
    bash "$root/scripts/residual-scan.sh" "${common[@]}" \
      --output "$root/evidence/cleanup/../cleanup/residual.json" 2>&1)
status=$?
set -e
if [[ "$status" -eq 0 ]] || ! grep -Fq 'FIXTURE_RUNTIME_OUTPUT_BLOCKED' <<<"$output"; then
  echo 'fixture residual scan did not block a canonical output alias' >&2
  exit 1
fi
[[ ! -s "$work/aws.log" ]]

run_scan "$work/evidence/generated-residual.json"
jq -e '
  .evidenceGrade == "STATIC" and .status == "PASS" and
  [.retained[] | select(.kind | IN("Namespace","PersistentVolumeClaim","VolumeSnapshot","VolumeSnapshotContent")) | [.kind,.id]] ==
    [["Namespace","app-recovery"],["PersistentVolumeClaim","app-dev/data-postgresql-0"],["VolumeSnapshot","app-dev/data-snapshot"],["VolumeSnapshotContent","data-content"]] and
  all(.retained[]; .presentAfterCleanup == true)
' "$work/evidence/generated-residual.json" >/dev/null
grep -Fq 'ec2 describe-snapshots' "$work/aws.log"
grep -Fq 'ecr describe-repositories' "$work/aws.log"
grep -Fq 'secretsmanager describe-secret' "$work/aws.log"
if grep -Eq 'app-recovery|data-postgresql-0|data-snapshot|data-content' "$work/aws.log"; then
  echo 'Kubernetes retained identities were sent to an AWS presence API' >&2
  exit 1
fi

jq '
  .retained |= map(
    if .kind == "Namespace" or .kind == "VolumeSnapshotContent" then
      .namespace = "app-dev"
    else . end
  )
' "$work/evidence/removal.json" >"$work/evidence/removal-invalid-cluster-scope.json"
invalid_removal_sha=$(raw_sha256 "$work/evidence/removal-invalid-cluster-scope.json")
jq --arg removal "$invalid_removal_sha" '
  .gitopsRemovalSha256=$removal |
  .retainedStorage |= map(
    if .kind == "Namespace" or .kind == "VolumeSnapshotContent" then
      .namespace = "app-dev"
    else . end
  )
' "$work/evidence/pre-destroy.json" >"$work/evidence/pre-destroy-invalid-cluster-scope.json"
: >"$work/aws.log"
if COURSE_CHECK_BIN_DIR="$root/tests/helpers/residual-retained-bin" \
  COURSE_FAKE_AWS_LOG="$work/aws.log" AWS_PROFILE=course AWS_REGION=ap-northeast-2 \
  AWS_ACCOUNT_ID=123456789012 COURSE_ID=course-2026 \
  RESIDUAL_SCAN_ATTEMPTS=1 RESIDUAL_SCAN_DELAY_SECONDS=0 \
  bash "$root/scripts/residual-scan.sh" \
    --inventory "$work/evidence/inventory.json" \
    --retain-decisions "$work/evidence/decisions.json" \
    --kubernetes-pre-destroy "$work/evidence/pre-destroy-invalid-cluster-scope.json" \
    --gitops-removal "$work/evidence/removal-invalid-cluster-scope.json" \
    --output "$work/evidence/invalid-cluster-scope-residual.json" >/dev/null 2>&1; then
  echo 'cluster-scoped retained Kubernetes identities accepted a namespace' >&2
  exit 1
fi
[[ ! -s "$work/aws.log" && ! -e "$work/evidence/invalid-cluster-scope-residual.json" ]]

: >"$work/aws.log"
rm -f "$work/evidence/missing-aws-residual.json"
if COURSE_FAKE_MISSING_RETAINED_AWS=true run_scan "$work/evidence/missing-aws-residual.json" >/dev/null 2>&1; then
  echo 'missing retained AWS handles were accepted' >&2
  exit 1
fi
[[ ! -e "$work/evidence/missing-aws-residual.json" ]]
grep -Fq 'ec2 describe-snapshots' "$work/aws.log"

jq '.retainedStorage |= map(select(.kind != "VolumeSnapshotContent"))' \
  "$work/evidence/pre-destroy.json" >"$work/evidence/pre-destroy-missing-content.json"
: >"$work/aws.log"
if COURSE_CHECK_BIN_DIR="$root/tests/helpers/residual-retained-bin" \
  COURSE_FAKE_AWS_LOG="$work/aws.log" AWS_PROFILE=course AWS_REGION=ap-northeast-2 \
  AWS_ACCOUNT_ID=123456789012 COURSE_ID=course-2026 \
  bash "$root/scripts/residual-scan.sh" \
    --inventory "$work/evidence/inventory.json" \
    --retain-decisions "$work/evidence/decisions.json" \
    --kubernetes-pre-destroy "$work/evidence/pre-destroy-missing-content.json" \
    --gitops-removal "$work/evidence/removal.json" \
    --output "$work/evidence/mismatched-kubernetes-residual.json" >/dev/null 2>&1; then
  echo 'a pre-destroy/removal retained Kubernetes mismatch was accepted' >&2
  exit 1
fi
[[ ! -s "$work/aws.log" && ! -e "$work/evidence/mismatched-kubernetes-residual.json" ]]

config_map=$(jq -n '{kind:"ConfigMap",id:"app-dev/manual-retain",environment:"dev",classification:"manual",owner:"course",managedBy:"terraform",billable:false,decision:"RETAIN",reason:"manual record",followUpAction:"review"}')
jq --argjson item "$config_map" '.resources += [$item] | .resources |= sort_by(.kind,.id)' \
  "$work/evidence/inventory.json" >"$work/evidence/inventory-unsupported.json"
unsupported_inventory_sha=$(raw_sha256 "$work/evidence/inventory-unsupported.json")
jq --arg inventory "$unsupported_inventory_sha" --argjson item "$config_map" '
  .inventorySha256=$inventory |
  .decisions += [($item | {kind,id,decision,reason,followUpAction})] |
  .decisions |= sort_by(.kind,.id)
' "$work/evidence/decisions.json" >"$work/evidence/decisions-unsupported.json"
: >"$work/aws.log"
if COURSE_CHECK_BIN_DIR="$root/tests/helpers/residual-retained-bin" \
  COURSE_FAKE_AWS_LOG="$work/aws.log" AWS_PROFILE=course AWS_REGION=ap-northeast-2 \
  AWS_ACCOUNT_ID=123456789012 COURSE_ID=course-2026 \
  RESIDUAL_SCAN_ATTEMPTS=1 RESIDUAL_SCAN_DELAY_SECONDS=0 \
  bash "$root/scripts/residual-scan.sh" \
    --inventory "$work/evidence/inventory-unsupported.json" \
    --retain-decisions "$work/evidence/decisions-unsupported.json" \
    --kubernetes-pre-destroy "$work/evidence/pre-destroy.json" \
    --gitops-removal "$work/evidence/removal.json" \
    --output "$work/evidence/unsupported-kind-residual.json" >/dev/null 2>&1; then
  echo 'an unsupported retained Kubernetes kind was carried without live evidence' >&2
  exit 1
fi
[[ ! -e "$work/evidence/unsupported-kind-residual.json" ]]

echo 'PASS: residual scan carries only digest-bound retained Kubernetes identities and still live-checks AWS handles'
