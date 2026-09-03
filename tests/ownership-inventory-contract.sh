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

timestamp_dir="$tmp_dir/timestamps"
mkdir -p "$timestamp_dir"
prepare_cleanup_fixtures "$root" "$timestamp_dir" ap-northeast-2

assert_timestamp_rejected() {
  local label=$1 status
  shift
  set +e
  (COURSE_CHECK_BIN_DIR="$tmp_dir" AWS_REGION=ap-northeast-2 AWS_ACCOUNT_ID=123456789012 \
    COURSE_ID=course-2026 "$@") >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || {
    echo "expected canonical cleanup timestamp rejection: $label" >&2
    exit 1
  }
}

while IFS='|' read -r form value; do
  inventory_candidate="$timestamp_dir/inventory-$form.json"
  jq --arg value "$value" '.observedAt=$value' "$timestamp_dir/inventory.json" >"$inventory_candidate"
  assert_timestamp_rejected "inventory-observedAt-$form" \
    cleanup_validate_inventory "$inventory_candidate"

  decisions_candidate="$timestamp_dir/decisions-$form.json"
  jq --arg value "$value" '.approvedAt=$value' "$timestamp_dir/decisions.json" >"$decisions_candidate"
  assert_timestamp_rejected "decisions-approvedAt-$form" \
    cleanup_validate_decisions "$timestamp_dir/inventory.json" "$decisions_candidate"

  freeze_candidate="$timestamp_dir/freeze-$form.json"
  removal_for_freeze="$timestamp_dir/removal-for-freeze-$form.json"
  jq --arg value "$value" '.observedAt=$value' "$timestamp_dir/freeze.json" >"$freeze_candidate"
  freeze_sha=$(raw_sha256 "$freeze_candidate")
  jq --arg freeze "$freeze_sha" '.freezeEvidenceSha256=$freeze' \
    "$timestamp_dir/removal.json" >"$removal_for_freeze"
  assert_timestamp_rejected "freeze-observedAt-$form" \
    cleanup_validate_freeze_removal "$timestamp_dir/inventory.json" "$freeze_candidate" "$removal_for_freeze"

  support_freeze="$timestamp_dir/support-freeze-$form.json"
  removal_candidate="$timestamp_dir/removal-$form.json"
  jq '.observedAt="2020-01-01T00:00:00Z"' "$timestamp_dir/freeze.json" >"$support_freeze"
  support_freeze_sha=$(raw_sha256 "$support_freeze")
  jq --arg value "$value" --arg freeze "$support_freeze_sha" \
    '.observedAt=$value | .freezeEvidenceSha256=$freeze' \
    "$timestamp_dir/removal.json" >"$removal_candidate"
  assert_timestamp_rejected "removal-observedAt-$form" \
    cleanup_validate_freeze_removal "$timestamp_dir/inventory.json" "$support_freeze" "$removal_candidate"

  pre_candidate="$timestamp_dir/pre-destroy-$form.json"
  jq --arg value "$value" '.observedAt=$value' "$timestamp_dir/pre-destroy.json" >"$pre_candidate"
  assert_timestamp_rejected "pre-destroy-observedAt-$form" \
    cleanup_validate_pre_destroy "$timestamp_dir/inventory.json" "$timestamp_dir/removal.json" "$pre_candidate"

  residual_candidate="$timestamp_dir/residual-$form.json"
  jq --arg value "$value" '.observedAt=$value' "$timestamp_dir/residual.json" >"$residual_candidate"
  assert_timestamp_rejected "residual-observedAt-$form" \
    cleanup_validate_residual "$timestamp_dir/inventory.json" "$timestamp_dir/decisions.json" \
      "$timestamp_dir/pre-destroy.json" "$timestamp_dir/removal.json" "$residual_candidate"
done <<'TIMESTAMP_CASES'
invalid-calendar|2020-02-30T00:00:00Z
fractional|2020-03-01T00:00:00.123Z
offset|2020-03-01T09:00:00+09:00
TIMESTAMP_CASES

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
