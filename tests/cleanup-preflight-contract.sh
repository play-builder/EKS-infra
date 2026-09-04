#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/lib/evidence-common.sh"
source "$root/scripts/lib/cleanup-evidence.sh"
source "$root/tests/cleanup-fixture-helpers.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/fake-bin"
prepare_saved_plan_manifest "$tmp_dir/plans" "$tmp_dir/saved-plans.json"
prepare_realistic_destroy_plan_jsons "$tmp_dir/plan-json"

cat >"$tmp_dir/fake-bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$*" == *" show -json "* ]] || { echo "unexpected terraform command: $*" >&2; exit 97; }
if [[ -n "${COURSE_FAKE_PLAN_JSON:-}" ]]; then
  cat "$COURSE_FAKE_PLAN_JSON"
  exit 0
fi
chdir=''
for argument in "$@"; do case "$argument" in -chdir=*) chdir=${argument#-chdir=} ;; esac; done
layer=${chdir#"$COURSE_FAKE_REPO_ROOT/"}
cat "$COURSE_FAKE_PLAN_JSON_DIR/${layer//\//__}.json"
EOF
chmod +x "$tmp_dir/fake-bin/terraform"
export COURSE_FAKE_REPO_ROOT="$root"
export COURSE_FAKE_PLAN_JSON_DIR="$tmp_dir/plan-json"

run_valid() {
  COURSE_CHECK_BIN_DIR="$tmp_dir/fake-bin" \
  COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 \
  AWS_REGION=ap-northeast-2 COURSE_PROJECT=playdevops \
    bash "$root/scripts/course-check.sh" ch26 --cleanup-preflight --saved-plan-manifest "$tmp_dir/saved-plans.json" \
      --inventory-source "$root/tests/fixtures/cleanup-ownership-valid.json" \
      --inventory-output "$tmp_dir/inventory.json" --retain-template "$tmp_dir/retain-template.json" \
      --preflight-output "$tmp_dir/preflight.json"
  jq -e '.evidenceGrade == "STATIC" and (.resources | length == 7)' "$tmp_dir/inventory.json" >/dev/null
  jq -e '.evidenceGrade == "LOCAL_RUNTIME" and .status == "PENDING"' "$tmp_dir/retain-template.json" >/dev/null
  jq -e '.evidenceGrade == "STATIC" and .status == "PASS"' "$tmp_dir/preflight.json" >/dev/null
  course_assert_file_mode "$tmp_dir/inventory.json" 600
}
run_valid

whitespace_inventory="$tmp_dir/ownership-whitespace.json"
jq '.resources[0].classification=" "' \
  "$root/tests/fixtures/cleanup-ownership-valid.json" >"$whitespace_inventory"

whitespace_rejected=true
if COURSE_CHECK_BIN_DIR="$tmp_dir/fake-bin" COURSE_FAKE_PLAN_JSON="$root/tests/fixtures/cleanup-course-owned.json" \
  COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 \
  AWS_REGION=ap-northeast-2 COURSE_PROJECT=playdevops \
    bash "$root/scripts/course-check.sh" ch26 --cleanup-preflight \
      --saved-plan-manifest "$tmp_dir/saved-plans.json" \
      --inventory-source "$whitespace_inventory" \
      --inventory-output "$tmp_dir/whitespace-inventory.json" \
      --retain-template "$tmp_dir/whitespace-retain.json" \
      --preflight-output "$tmp_dir/whitespace-preflight.json" >/dev/null 2>&1; then
  echo 'cleanup preflight accepted whitespace-only ownership classification' >&2
  whitespace_rejected=false
fi
for output_path in "$tmp_dir/whitespace-inventory.json" "$tmp_dir/whitespace-retain.json" \
  "$tmp_dir/whitespace-preflight.json"; do
  if [[ -e "$output_path" ]]; then
    echo 'invalid cleanup ownership created a published output' >&2
    whitespace_rejected=false
  fi
done

sentinel_inventory="$tmp_dir/sentinel-inventory.json"
sentinel_retain="$tmp_dir/sentinel-retain.json"
sentinel_preflight="$tmp_dir/sentinel-preflight.json"
for output_path in "$sentinel_inventory" "$sentinel_retain" "$sentinel_preflight"; do
  printf '%s\n' '{"sentinel":true}' >"$output_path"
done
sentinel_digest_before=$(shasum -a 256 "$sentinel_inventory" "$sentinel_retain" "$sentinel_preflight")
if COURSE_CHECK_BIN_DIR="$tmp_dir/fake-bin" COURSE_FAKE_PLAN_JSON="$root/tests/fixtures/cleanup-course-owned.json" \
  COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 \
  AWS_REGION=ap-northeast-2 COURSE_PROJECT=playdevops \
    bash "$root/scripts/course-check.sh" ch26 --cleanup-preflight \
      --saved-plan-manifest "$tmp_dir/saved-plans.json" \
      --inventory-source "$whitespace_inventory" \
      --inventory-output "$sentinel_inventory" --retain-template "$sentinel_retain" \
      --preflight-output "$sentinel_preflight" >/dev/null 2>&1; then
  echo 'cleanup preflight accepted whitespace-only ownership over sentinel outputs' >&2
  whitespace_rejected=false
fi
sentinel_digest_after=$(shasum -a 256 "$sentinel_inventory" "$sentinel_retain" "$sentinel_preflight")
if [[ "$sentinel_digest_after" != "$sentinel_digest_before" ]]; then
  echo 'invalid cleanup ownership replaced an existing output' >&2
  whitespace_rejected=false
fi
[[ "$whitespace_rejected" == true ]] || exit 1

bom_inventory="$tmp_dir/ownership-bom.json"
bom=$(printf '\357\273\277')
jq --arg blank "$bom" '.resources[0].classification=$blank' \
  "$root/tests/fixtures/cleanup-ownership-valid.json" >"$bom_inventory"
bom_rejected=true
if COURSE_CHECK_BIN_DIR="$tmp_dir/fake-bin" COURSE_FAKE_PLAN_JSON="$root/tests/fixtures/cleanup-course-owned.json" \
  COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 \
  AWS_REGION=ap-northeast-2 COURSE_PROJECT=playdevops \
    bash "$root/scripts/course-check.sh" ch26 --cleanup-preflight \
      --saved-plan-manifest "$tmp_dir/saved-plans.json" \
      --inventory-source "$bom_inventory" \
      --inventory-output "$tmp_dir/bom-inventory.json" \
      --retain-template "$tmp_dir/bom-retain.json" \
      --preflight-output "$tmp_dir/bom-preflight.json" >/dev/null 2>&1; then
  echo 'cleanup preflight accepted BOM-only ownership classification' >&2
  bom_rejected=false
fi
for output_path in "$tmp_dir/bom-inventory.json" "$tmp_dir/bom-retain.json" \
  "$tmp_dir/bom-preflight.json"; do
  if [[ -e "$output_path" ]]; then
    echo 'BOM-only cleanup ownership created a published output' >&2
    bom_rejected=false
  fi
done
sentinel_digest_before=$(shasum -a 256 "$sentinel_inventory" "$sentinel_retain" "$sentinel_preflight")
if COURSE_CHECK_BIN_DIR="$tmp_dir/fake-bin" COURSE_FAKE_PLAN_JSON="$root/tests/fixtures/cleanup-course-owned.json" \
  COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 \
  AWS_REGION=ap-northeast-2 COURSE_PROJECT=playdevops \
    bash "$root/scripts/course-check.sh" ch26 --cleanup-preflight \
      --saved-plan-manifest "$tmp_dir/saved-plans.json" \
      --inventory-source "$bom_inventory" \
      --inventory-output "$sentinel_inventory" --retain-template "$sentinel_retain" \
      --preflight-output "$sentinel_preflight" >/dev/null 2>&1; then
  echo 'cleanup preflight accepted BOM-only ownership over sentinel outputs' >&2
  bom_rejected=false
fi
sentinel_digest_after=$(shasum -a 256 "$sentinel_inventory" "$sentinel_retain" "$sentinel_preflight")
if [[ "$sentinel_digest_after" != "$sentinel_digest_before" ]]; then
  echo 'BOM-only cleanup ownership replaced an existing output' >&2
  bom_rejected=false
fi
[[ "$bom_rejected" == true ]] || exit 1

for protected_id in \
  arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:shared-provider \
  arn:aws:ecr:ap-northeast-2:123456789012:repository/course/sample-app \
  snap-retained-001; do
  protected_plan="$tmp_dir/protected-plan.json"
  jq --arg id "$protected_id" '.resource_changes[1].change.before.id=$id' \
    "$tmp_dir/plan-json/environments__prod__04-workloads__argocd.json" >"$protected_plan"
  rm -f "$tmp_dir/rejected-inventory.json" "$tmp_dir/rejected-retain.json" "$tmp_dir/rejected-preflight.json"
  set +e
  output=$(COURSE_CHECK_BIN_DIR="$tmp_dir/fake-bin" COURSE_FAKE_PLAN_JSON="$protected_plan" \
    COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 \
    AWS_REGION=ap-northeast-2 COURSE_PROJECT=playdevops \
      bash "$root/scripts/course-check.sh" ch26 --cleanup-preflight --saved-plan-manifest "$tmp_dir/saved-plans.json" \
        --inventory-source "$root/tests/fixtures/cleanup-ownership-valid.json" \
        --inventory-output "$tmp_dir/rejected-inventory.json" --retain-template "$tmp_dir/rejected-retain.json" \
        --preflight-output "$tmp_dir/rejected-preflight.json" 2>&1)
  status=$?
  set -e
  if [[ "$status" -eq 0 || -e "$tmp_dir/rejected-inventory.json" ]]; then
    echo "expected protected delete rejection for $protected_id" >&2
    exit 1
  fi
  grep -Fq 'SAVED_DESTROY_PLAN_OWNERSHIP_MISMATCH' <<<"$output"
done

non_destroy_plan="$tmp_dir/non-destroy-plan.json"
jq '.resource_changes[0].change.actions=["create"]' \
  "$tmp_dir/plan-json/environments__prod__04-workloads__argocd.json" >"$non_destroy_plan"
rm -f "$tmp_dir/non-destroy-inventory.json" "$tmp_dir/non-destroy-retain.json" "$tmp_dir/non-destroy-preflight.json"
if COURSE_CHECK_BIN_DIR="$tmp_dir/fake-bin" COURSE_FAKE_PLAN_JSON="$non_destroy_plan" \
  COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 AWS_REGION=ap-northeast-2 COURSE_PROJECT=playdevops \
    bash "$root/scripts/course-check.sh" ch26 --cleanup-preflight \
      --saved-plan-manifest "$tmp_dir/saved-plans.json" \
      --inventory-source "$root/tests/fixtures/cleanup-ownership-valid.json" \
      --inventory-output "$tmp_dir/non-destroy-inventory.json" \
      --retain-template "$tmp_dir/non-destroy-retain.json" \
      --preflight-output "$tmp_dir/non-destroy-preflight.json" >/dev/null 2>&1; then
  echo 'cleanup preflight accepted a saved plan containing a non-delete action' >&2
  exit 1
fi
[[ ! -e "$tmp_dir/non-destroy-inventory.json" && ! -e "$tmp_dir/non-destroy-preflight.json" ]]

rm -f "$tmp_dir/runtime-inventory.json" "$tmp_dir/runtime-retain.json" "$tmp_dir/runtime-preflight.json"
set +e
output=$(COURSE_FAKE_PLAN_JSON="$root/tests/fixtures/cleanup-course-owned.json" COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 AWS_REGION=ap-northeast-2 COURSE_PROJECT=playdevops \
  bash "$root/scripts/cleanup-preflight.sh" --saved-plan-manifest "$tmp_dir/saved-plans.json" \
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
output=$(COURSE_CHECK_BIN_DIR="$tmp_dir/fake-bin" COURSE_FAKE_PLAN_JSON="$root/tests/fixtures/cleanup-course-owned.json" \
  COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 \
  AWS_REGION=ap-northeast-2 COURSE_PROJECT=playdevops \
    bash "$root/scripts/cleanup-preflight.sh" --saved-plan-manifest "$tmp_dir/saved-plans.json" \
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
