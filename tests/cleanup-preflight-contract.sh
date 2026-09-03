#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/fake-bin"

run_valid() {
  COURSE_CHECK_BIN_DIR="$tmp_dir/fake-bin" COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 \
  AWS_REGION=ap-northeast-2 COURSE_PROJECT=playdevops \
    bash "$root/scripts/cleanup-preflight.sh" --plan "$root/tests/fixtures/cleanup-course-owned.json" \
      --inventory-source "$root/tests/fixtures/cleanup-ownership-valid.json" \
      --inventory-output "$tmp_dir/inventory.json" --retain-template "$tmp_dir/retain-template.json" \
      --preflight-output "$tmp_dir/preflight.json"
  jq -e '.evidenceGrade == "STATIC" and (.resources | length == 7)' "$tmp_dir/inventory.json" >/dev/null
  jq -e '.evidenceGrade == "LOCAL_RUNTIME" and .status == "PENDING"' "$tmp_dir/retain-template.json" >/dev/null
  jq -e '.evidenceGrade == "STATIC" and .status == "PASS"' "$tmp_dir/preflight.json" >/dev/null
  [[ $(stat -f '%Lp' "$tmp_dir/inventory.json") == 600 ]]
}
run_valid

for plan in cleanup-external-oidc-plan.json cleanup-external-shared.json cleanup-retained.json; do
  rm -f "$tmp_dir/rejected-inventory.json" "$tmp_dir/rejected-retain.json" "$tmp_dir/rejected-preflight.json"
  set +e
  output=$(COURSE_CHECK_BIN_DIR="$tmp_dir/fake-bin" COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 \
    AWS_REGION=ap-northeast-2 COURSE_PROJECT=playdevops \
      bash "$root/scripts/cleanup-preflight.sh" --plan "$root/tests/fixtures/$plan" \
        --inventory-source "$root/tests/fixtures/cleanup-ownership-valid.json" \
        --inventory-output "$tmp_dir/rejected-inventory.json" --retain-template "$tmp_dir/rejected-retain.json" \
        --preflight-output "$tmp_dir/rejected-preflight.json" 2>&1)
  status=$?
  set -e
  if [[ "$status" -eq 0 || -e "$tmp_dir/rejected-inventory.json" ]]; then
    echo "expected protected delete rejection for $plan" >&2
    exit 1
  fi
  grep -Eq 'EXTERNAL_RESOURCE_DELETE_BLOCKED|RETAINED_RESOURCE_DELETE_BLOCKED' <<<"$output"
done

echo 'PASS: cleanup plan ownership preflight contract'
