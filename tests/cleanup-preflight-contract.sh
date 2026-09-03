#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/lib/evidence-common.sh"
source "$root/scripts/lib/cleanup-evidence.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/fake-bin"

run_valid() {
  COURSE_CHECK_BIN_DIR="$tmp_dir/fake-bin" COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 \
  AWS_REGION=ap-northeast-2 COURSE_PROJECT=playdevops \
    bash "$root/scripts/course-check.sh" ch26 --cleanup-preflight --plan "$root/tests/fixtures/cleanup-course-owned.json" \
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
      bash "$root/scripts/course-check.sh" ch26 --cleanup-preflight --plan "$root/tests/fixtures/$plan" \
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

rm -f "$tmp_dir/runtime-inventory.json" "$tmp_dir/runtime-retain.json" "$tmp_dir/runtime-preflight.json"
set +e
output=$(COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 AWS_REGION=ap-northeast-2 COURSE_PROJECT=playdevops \
  bash "$root/scripts/cleanup-preflight.sh" --plan "$root/tests/fixtures/cleanup-course-owned.json" \
    --inventory-source "$root/tests/fixtures/cleanup-ownership-valid.json" \
    --inventory-output "$tmp_dir/runtime-inventory.json" --retain-template "$tmp_dir/runtime-retain.json" \
    --preflight-output "$tmp_dir/runtime-preflight.json" 2>&1)
status=$?
set -e
if [[ "$status" -eq 0 ]] || ! grep -Fq 'NONCANONICAL_RUNTIME_OUTPUT' <<<"$output"; then
  echo 'real cleanup preflight accepted noncanonical evidence outputs' >&2
  exit 1
fi
[[ ! -e "$tmp_dir/runtime-inventory.json" && ! -e "$tmp_dir/runtime-retain.json" && ! -e "$tmp_dir/runtime-preflight.json" ]]

rm -f "$tmp_dir/fixture-inventory.json" "$tmp_dir/fixture-preflight.json"
set +e
output=$(COURSE_CHECK_BIN_DIR="$tmp_dir/fake-bin" COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 \
  AWS_REGION=ap-northeast-2 COURSE_PROJECT=playdevops \
    bash "$root/scripts/cleanup-preflight.sh" --plan "$root/tests/fixtures/cleanup-course-owned.json" \
      --inventory-source "$root/tests/fixtures/cleanup-ownership-valid.json" \
      --inventory-output "$tmp_dir/fixture-inventory.json" \
      --retain-template "$root/evidence/cleanup/../cleanup/retain-decisions.json" \
      --preflight-output "$tmp_dir/fixture-preflight.json" 2>&1)
status=$?
set -e
if [[ "$status" -eq 0 ]] || ! grep -Fq 'FIXTURE_RUNTIME_OUTPUT_BLOCKED' <<<"$output"; then
  echo 'fixture cleanup preflight did not block a canonical retain-decisions alias' >&2
  exit 1
fi
[[ ! -e "$tmp_dir/fixture-inventory.json" && ! -e "$tmp_dir/fixture-preflight.json" ]]

mkdir -p "$tmp_dir/boundary-repo/evidence/cleanup"
boundary_repo=$(cd -- "$tmp_dir/boundary-repo" && pwd -P)
cleanup_require_canonical_runtime_output \
  "$boundary_repo/evidence/cleanup/ownership-inventory.json" \
  "$boundary_repo" ownership-inventory.json

ln -s "$boundary_repo/evidence/cleanup" "$tmp_dir/cleanup-link"
set +e
output=$(COURSE_CHECK_BIN_DIR="$tmp_dir/fake-bin" cleanup_require_canonical_runtime_output \
  "$tmp_dir/cleanup-link/ownership-inventory.json" "$boundary_repo" ownership-inventory.json 2>&1)
status=$?
set -e
if [[ "$status" -eq 0 ]] || ! grep -Fq 'FIXTURE_RUNTIME_OUTPUT_BLOCKED' <<<"$output"; then
  echo 'fixture output symlink resolved to the canonical cleanup path' >&2
  exit 1
fi

mkdir -p "$tmp_dir/escaped-output"
mkdir -p "$tmp_dir/escaped-repo"
escaped_repo=$(cd -- "$tmp_dir/escaped-repo" && pwd -P)
ln -s "$tmp_dir/escaped-output" "$tmp_dir/escaped-repo/evidence"
set +e
output=$(cleanup_require_canonical_runtime_output \
  "$escaped_repo/evidence/cleanup/ownership-inventory.json" \
  "$escaped_repo" ownership-inventory.json 2>&1)
status=$?
set -e
if [[ "$status" -eq 0 ]] || ! grep -Fq 'RUNTIME_OUTPUT_SYMLINK_ESCAPE_BLOCKED' <<<"$output"; then
  echo 'real cleanup output accepted a canonical-parent symlink escape' >&2
  exit 1
fi

echo 'PASS: cleanup plan ownership preflight contract'
