#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
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

echo 'PASS: canonical cleanup ownership and evidence schemas'
