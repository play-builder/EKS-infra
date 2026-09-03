#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/lib/evidence-common.sh"
source "$root/scripts/lib/cleanup-evidence.sh"
source "$root/tests/cleanup-fixture-helpers.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

for region in ap-northeast-2 us-east-1; do
  mkdir -p "$tmp_dir/$region"
  prepare_cleanup_fixtures "$root" "$tmp_dir/$region" "$region"
  COURSE_CHECK_BIN_DIR="$tmp_dir" AWS_REGION="$region" AWS_ACCOUNT_ID=123456789012 COURSE_ID=course-2026 \
    bash "$root/scripts/residual-scan.sh" --validate-only \
      --inventory "$tmp_dir/$region/inventory.json" --retain-decisions "$tmp_dir/$region/decisions.json" \
      --kubernetes-pre-destroy "$tmp_dir/$region/pre-destroy.json" \
      --gitops-removal "$tmp_dir/$region/removal.json" --residual "$tmp_dir/$region/residual.json"
done

jq '.decisions[0].decision="DELETE"' "$tmp_dir/ap-northeast-2/decisions.json" >"$tmp_dir/delete-decision.json"
jq '.remainingWorkloads.jobs=1' "$tmp_dir/ap-northeast-2/pre-destroy.json" >"$tmp_dir/nonzero-pre.json"
jq '.externalShared[0].presentAfterCleanup=false' "$tmp_dir/ap-northeast-2/residual.json" >"$tmp_dir/missing-external.json"

assert_rejected() {
  local decisions=$1 pre=$2 residual=$3 status
  set +e
  COURSE_CHECK_BIN_DIR="$tmp_dir" AWS_REGION=ap-northeast-2 AWS_ACCOUNT_ID=123456789012 COURSE_ID=course-2026 \
    bash "$root/scripts/residual-scan.sh" --validate-only \
      --inventory "$tmp_dir/ap-northeast-2/inventory.json" --retain-decisions "$decisions" \
      --kubernetes-pre-destroy "$pre" --gitops-removal "$tmp_dir/ap-northeast-2/removal.json" \
      --residual "$residual" >/dev/null 2>&1
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    echo 'expected canonical cleanup evidence rejection' >&2
    exit 1
  fi
}

assert_rejected "$tmp_dir/delete-decision.json" "$tmp_dir/ap-northeast-2/pre-destroy.json" "$tmp_dir/ap-northeast-2/residual.json"
assert_rejected "$tmp_dir/ap-northeast-2/decisions.json" "$tmp_dir/nonzero-pre.json" "$tmp_dir/ap-northeast-2/residual.json"
assert_rejected "$tmp_dir/ap-northeast-2/decisions.json" "$tmp_dir/ap-northeast-2/pre-destroy.json" "$tmp_dir/missing-external.json"

assert_inventory_rejected() {
  local candidate=$1 status
  set +e
  (COURSE_CHECK_BIN_DIR="$tmp_dir" AWS_REGION=ap-northeast-2 AWS_ACCOUNT_ID=123456789012 COURSE_ID=course-2026 \
    cleanup_validate_inventory "$candidate") >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || {
    echo "expected whitespace-only cleanup ownership rejection: $candidate" >&2
    exit 1
  }
}

for field in kind id classification owner reason followUpAction; do
  candidate="$tmp_dir/whitespace-$field.json"
  jq --arg field "$field" '
    if $field == "reason" or $field == "followUpAction" then
      .resources[0][$field] = " "
    else
      .resources[0][$field] = " " | .resources |= sort_by(.kind,.id)
    end
  ' "$tmp_dir/ap-northeast-2/inventory.json" >"$candidate"
  assert_inventory_rejected "$candidate"
done

bom=$(printf '\357\273\277')
jq --arg blank "$bom" '.resources[0].classification=$blank' \
  "$tmp_dir/ap-northeast-2/inventory.json" >"$tmp_dir/bom-classification.json"
assert_inventory_rejected "$tmp_dir/bom-classification.json"

cluster_prefix='arn:aws:eks:ap-northeast-2:123456789012:cluster/'
hundred_character_name=$(printf 'a%.0s' {1..100})
jq --arg prefix "$cluster_prefix" --arg name "$hundred_character_name" '
  .clusters[0].clusterArn=($prefix+"a") |
  .clusters[1].clusterArn=($prefix+$name)
' "$tmp_dir/ap-northeast-2/freeze.json" >"$tmp_dir/canonical-cluster-freeze.json"
canonical_freeze_sha=$(raw_sha256 "$tmp_dir/canonical-cluster-freeze.json")
jq --arg prefix "$cluster_prefix" --arg name "$hundred_character_name" --arg freeze "$canonical_freeze_sha" '
  .freezeEvidenceSha256=$freeze |
  .clusters[0].clusterArn=($prefix+"a") |
  .clusters[1].clusterArn=($prefix+$name)
' "$tmp_dir/ap-northeast-2/removal.json" >"$tmp_dir/canonical-cluster-removal.json"
COURSE_CHECK_BIN_DIR="$tmp_dir" AWS_REGION=ap-northeast-2 AWS_ACCOUNT_ID=123456789012 COURSE_ID=course-2026 \
  cleanup_validate_freeze_removal "$tmp_dir/ap-northeast-2/inventory.json" \
    "$tmp_dir/canonical-cluster-freeze.json" "$tmp_dir/canonical-cluster-removal.json"

assert_cleanup_cluster_rejected() {
  local freeze_file=$1 removal_file=$2 status
  set +e
  (COURSE_CHECK_BIN_DIR="$tmp_dir" AWS_REGION=ap-northeast-2 AWS_ACCOUNT_ID=123456789012 COURSE_ID=course-2026 \
    cleanup_validate_freeze_removal "$tmp_dir/ap-northeast-2/inventory.json" "$freeze_file" "$removal_file") \
    >/dev/null 2>&1
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    echo 'expected noncanonical cleanup cluster ARN rejection' >&2
    exit 1
  fi
}

jq '.clusters |= map(.clusterArn += "/junk")' \
  "$tmp_dir/ap-northeast-2/freeze.json" >"$tmp_dir/trailing-cluster-freeze.json"
trailing_freeze_sha=$(raw_sha256 "$tmp_dir/trailing-cluster-freeze.json")
jq --arg freeze "$trailing_freeze_sha" '
  .freezeEvidenceSha256=$freeze | .clusters |= map(.clusterArn += "/junk")
' "$tmp_dir/ap-northeast-2/removal.json" >"$tmp_dir/trailing-cluster-removal.json"
assert_cleanup_cluster_rejected "$tmp_dir/trailing-cluster-freeze.json" "$tmp_dir/trailing-cluster-removal.json"

hundred_one_character_name=$(printf 'a%.0s' {1..101})
jq --arg prefix "$cluster_prefix" --arg name "$hundred_one_character_name" '
  .clusters[0].clusterArn=($prefix+$name) | .clusters[1].clusterArn=($prefix+"prod")
' "$tmp_dir/ap-northeast-2/freeze.json" >"$tmp_dir/long-cluster-freeze.json"
long_freeze_sha=$(raw_sha256 "$tmp_dir/long-cluster-freeze.json")
jq --arg prefix "$cluster_prefix" --arg name "$hundred_one_character_name" --arg freeze "$long_freeze_sha" '
  .freezeEvidenceSha256=$freeze |
  .clusters[0].clusterArn=($prefix+$name) | .clusters[1].clusterArn=($prefix+"prod")
' "$tmp_dir/ap-northeast-2/removal.json" >"$tmp_dir/long-cluster-removal.json"
assert_cleanup_cluster_rejected "$tmp_dir/long-cluster-freeze.json" "$tmp_dir/long-cluster-removal.json"

jq '.clusters[0].application.name=" "' \
  "$tmp_dir/ap-northeast-2/freeze.json" >"$tmp_dir/whitespace-application-freeze.json"
whitespace_application_freeze_sha=$(raw_sha256 "$tmp_dir/whitespace-application-freeze.json")
jq --arg freeze "$whitespace_application_freeze_sha" '.freezeEvidenceSha256=$freeze' \
  "$tmp_dir/ap-northeast-2/removal.json" >"$tmp_dir/whitespace-application-removal.json"
assert_cleanup_cluster_rejected \
  "$tmp_dir/whitespace-application-freeze.json" "$tmp_dir/whitespace-application-removal.json"

echo 'PASS: canonical cleanup ownership and evidence schemas'
