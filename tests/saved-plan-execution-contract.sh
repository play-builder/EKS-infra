#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/lib/evidence-common.sh"
source "$root/scripts/lib/cleanup-evidence.sh"
source "$root/tests/cleanup-fixture-helpers.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin" "$tmp_dir/evidence"
prepare_cleanup_fixtures "$root" "$tmp_dir/evidence" ap-northeast-2
prepare_saved_plan_manifest "$tmp_dir/plans" "$tmp_dir/saved-plans.json"
prepare_realistic_destroy_plan_jsons "$tmp_dir/plan-json"

cat >"$tmp_dir/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
chdir=''
for argument in "$@"; do
  case "$argument" in -chdir=*) chdir=${argument#-chdir=} ;; esac
done
layer=${chdir#"$COURSE_FAKE_REPO_ROOT/"}
if [[ " $* " == *" show -json "* ]]; then
  plan_path=${!#}
  if [[ -n "${COURSE_FAKE_INVALID_NOOP_PLAN_PATH:-}" && "$plan_path" == "$COURSE_FAKE_INVALID_NOOP_PLAN_PATH" ]]; then
    printf '%s\n' '{"resource_changes":[]}'
    exit 0
  fi
  if [[ -n "${COURSE_FAKE_NOOP_PLAN_PATH:-}" && "$plan_path" == "$COURSE_FAKE_NOOP_PLAN_PATH" ]]; then
    cat "$COURSE_FAKE_GENUINE_NOOP_JSON"
    exit 0
  fi
  cat "$COURSE_FAKE_PLAN_JSON_DIR/${layer//\//__}.json"
  exit 0
fi
[[ " $* " == *" apply "* ]] || { echo "unexpected terraform command: $*" >&2; exit 97; }
printf '%s\n' "$layer" >>"$COURSE_FAKE_MUTATION_LOG"
if [[ -n "${COURSE_FAKE_FAIL_LAYER:-}" && "$layer" == "$COURSE_FAKE_FAIL_LAYER" ]]; then
  exit 42
fi
EOF
chmod +x "$tmp_dir/bin/terraform"
: >"$tmp_dir/mutations.log"

export PATH="$tmp_dir/bin:$PATH"
export COURSE_FAKE_REPO_ROOT="$root"
export COURSE_FAKE_PLAN_JSON_DIR="$tmp_dir/plan-json"
export COURSE_FAKE_GENUINE_NOOP_JSON="$root/tests/fixtures/terraform-plan-noop-valid.json"
export COURSE_FAKE_MUTATION_LOG="$tmp_dir/mutations.log"
export COURSE_ID=course-2026
export AWS_ACCOUNT_ID=123456789012
export AWS_REGION=ap-northeast-2
export COURSE_PROJECT=playdevops

progress="$tmp_dir/evidence/saved-plan-progress.json"
manifest="$tmp_dir/saved-plans.json"
inventory="$tmp_dir/evidence/inventory.json"

set +e
output=$({
  export COURSE_FAKE_FAIL_LAYER=environments/dev/04-workloads/argocd
  cleanup_apply_saved_plans "$manifest" "$root" "$inventory" "$progress" playdevops
} 2>&1)
status=$?
set -e
[[ "$status" -ne 0 ]] || { echo 'partial apply failure was not surfaced' >&2; exit 1; }

first_plan=$(jq -r '.plans[0].path' "$manifest")
failed_plan=$(jq -r '.plans[1].path' "$manifest")
[[ ! -e "$first_plan" ]] || { printf '%s\n' "$output" >&2; echo 'successfully applied binary plan was not deleted promptly' >&2; exit 1; }
[[ -f "$failed_plan" ]] || { echo 'failed binary plan was not preserved for reviewed recovery' >&2; exit 1; }
course_assert_file_mode "$failed_plan" 600
course_assert_file_mode "$progress" 600
jq -e '
  .schemaVersion == "course.saved-destroy-progress/v2" and .status == "IN_PROGRESS" and
  [.completed[].layer] == ["environments/prod/04-workloads/argocd"] and
  .inFlight.layer == "environments/dev/04-workloads/argocd"
' "$progress" >/dev/null

mutations_before=$(wc -l <"$tmp_dir/mutations.log" | tr -d ' ')
set +e
(cleanup_apply_saved_plans "$manifest" "$root" "$inventory" "$progress" playdevops) >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || { echo 'unchanged failed plan was retried without a new review' >&2; exit 1; }
[[ $(wc -l <"$tmp_dir/mutations.log" | tr -d ' ') -eq "$mutations_before" ]] || {
  echo 'unchanged failed plan caused a second mutation attempt' >&2
  exit 1
}

original_failed_plan=$failed_plan
replacement_a="$tmp_dir/plans/reviewed-replacement-a.tfplan"
printf 'reviewed replacement plan A\n' >"$replacement_a"
replacement_a_sha=$(raw_sha256 "$replacement_a")
jq --arg path "$replacement_a" --arg sha "$replacement_a_sha" \
  '.reviewedAt="2026-09-03T00:11:00Z" | .plans[1].path=$path | .plans[1].sha256=$sha' \
  "$manifest" >"$manifest.tmp"
mv "$manifest.tmp" "$manifest"

later_plan_json="$tmp_dir/plan-json/environments__prod__03-platform.json"
cp "$later_plan_json" "$tmp_dir/valid-later-plan.json"
jq '.resource_changes[0].change.actions=["create"]' "$later_plan_json" >"$later_plan_json.tmp"
mv "$later_plan_json.tmp" "$later_plan_json"
authorization_before_failed_recovery=$(jq -c '{manifestSha256,status,completed,inFlight}' "$progress")
mutations_before=$(wc -l <"$tmp_dir/mutations.log" | tr -d ' ')
set +e
output=$(COURSE_FAKE_NOOP_PLAN_PATH="$replacement_a" \
  cleanup_apply_saved_plans "$manifest" "$root" "$inventory" "$progress" playdevops 2>&1)
status=$?
set -e
[[ "$status" -ne 0 ]] || { echo 'replacement recovery accepted a later create action' >&2; exit 1; }
grep -Fq 'SAVED_DESTROY_PLAN_NOT_DELETE_ONLY' <<<"$output"
[[ $(jq -c '{manifestSha256,status,completed,inFlight}' "$progress") == "$authorization_before_failed_recovery" ]] || {
  echo 'failed replacement semantic preflight changed apply authorization state' >&2
  exit 1
}
[[ $(wc -l <"$tmp_dir/mutations.log" | tr -d ' ') -eq "$mutations_before" ]]
[[ -f "$original_failed_plan" && -f "$replacement_a" ]]
jq -e --arg candidate "$replacement_a" 'any(.registeredPlans[]; .path == $candidate)' "$progress" >/dev/null || {
  echo 'failed later-layer preflight did not register replacement candidate A' >&2
  exit 1
}
mv "$tmp_dir/valid-later-plan.json" "$later_plan_json"

replacement_b="$tmp_dir/plans/reviewed-replacement-b.tfplan"
printf 'reviewed replacement plan B\n' >"$replacement_b"
replacement_b_sha=$(raw_sha256 "$replacement_b")
jq --arg path "$replacement_b" --arg sha "$replacement_b_sha" \
  '.reviewedAt="2026-09-03T00:12:00Z" | .plans[1].path=$path | .plans[1].sha256=$sha' \
  "$manifest" >"$manifest.tmp"
mv "$manifest.tmp" "$manifest"

progress_before_invalid_noop=$(raw_sha256 "$progress")
mutations_before=$(wc -l <"$tmp_dir/mutations.log" | tr -d ' ')
set +e
(COURSE_FAKE_INVALID_NOOP_PLAN_PATH="$replacement_b" \
  cleanup_apply_saved_plans "$manifest" "$root" "$inventory" "$progress" playdevops) >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || { echo 'recovery accepted a no-op plan without Terraform format metadata' >&2; exit 1; }
[[ $(raw_sha256 "$progress") == "$progress_before_invalid_noop" ]]
[[ $(wc -l <"$tmp_dir/mutations.log" | tr -d ' ') -eq "$mutations_before" ]]

COURSE_FAKE_NOOP_PLAN_PATH="$replacement_b" \
  cleanup_apply_saved_plans "$manifest" "$root" "$inventory" "$progress" playdevops

jq -e '
  .schemaVersion == "course.saved-destroy-progress/v2" and .status == "COMPLETE" and
  (.completed | length == 8) and .completed[1].outcome == "RECOVERED_NO_CHANGES" and .inFlight == null
' "$progress" >/dev/null
[[ $(wc -l <"$tmp_dir/mutations.log" | tr -d ' ') -eq 8 ]]
[[ $(sed -n '1p' "$tmp_dir/mutations.log") == "environments/prod/04-workloads/argocd" ]]
[[ $(sed -n '3p' "$tmp_dir/mutations.log") == "environments/prod/03-platform" ]]
jq -e --arg original "$original_failed_plan" --arg candidateA "$replacement_a" --arg candidateB "$replacement_b" '
  any(.registeredPlans[]; .path == $original) and
  any(.registeredPlans[]; .path == $candidateA) and
  any(.registeredPlans[]; .path == $candidateB)
' "$progress" >/dev/null
while IFS= read -r saved_plan; do
  [[ ! -e "$saved_plan" ]] || { echo "terminal cleanup retained binary plan: $saved_plan" >&2; exit 1; }
done < <(jq -r '.registeredPlans[].path' "$progress" | sort -u)

printf 'saved destroy plan for %s\n' 'environments/prod/04-workloads/argocd' >"$first_plan"
chmod 600 "$first_plan"
jq '.status="IN_PROGRESS"' "$progress" >"$progress.tmp"
mv "$progress.tmp" "$progress"
chmod 600 "$progress"
mutations_before=$(wc -l <"$tmp_dir/mutations.log" | tr -d ' ')
cleanup_apply_saved_plans "$manifest" "$root" "$inventory" "$progress" playdevops
[[ ! -e "$first_plan" ]] || { echo 'completed resume did not clean an applied-plan leftover' >&2; exit 1; }
[[ $(wc -l <"$tmp_dir/mutations.log" | tr -d ' ') -eq "$mutations_before" ]]
jq -e '.status == "COMPLETE" and (.completed | length) == 8' "$progress" >/dev/null

cp "$manifest" "$tmp_dir/manifest-before-unbound-change.json"
jq '.reviewedAt="2026-09-03T00:13:00Z"' "$manifest" >"$manifest.tmp"
mv "$manifest.tmp" "$manifest"
set +e
(cleanup_apply_saved_plans "$manifest" "$root" "$inventory" "$progress" playdevops) >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || { echo 'progress accepted an unbound replacement manifest without an in-flight recovery' >&2; exit 1; }
mv "$tmp_dir/manifest-before-unbound-change.json" "$manifest"

invalid_complete="$tmp_dir/evidence/invalid-complete-progress.json"
jq '.completed = .completed[:1]' "$progress" >"$invalid_complete"
chmod 600 "$invalid_complete"
set +e
(cleanup_apply_saved_plans "$manifest" "$root" "$inventory" "$invalid_complete" playdevops) >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]] || { echo 'incomplete progress was accepted as terminally complete' >&2; exit 1; }

echo 'PASS: saved destroy plans resume only from digest-bound progress and clean binary plans'
