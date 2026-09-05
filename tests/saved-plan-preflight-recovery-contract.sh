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
for argument in "$@"; do case "$argument" in -chdir=*) chdir=${argument#-chdir=} ;; esac; done
layer=${chdir#"$COURSE_FAKE_REPO_ROOT/"}
if [[ " $* " == *" show -json "* ]]; then
  cat "$COURSE_FAKE_PLAN_JSON_DIR/${layer//\//__}.json"
  exit 0
fi
[[ " $* " == *" apply "* ]] || exit 97
printf '%s\n' "$layer" >>"$COURSE_FAKE_MUTATION_LOG"
EOF
chmod +x "$tmp_dir/bin/terraform"
: >"$tmp_dir/mutations.log"

export PATH="$tmp_dir/bin:$PATH"
export COURSE_FAKE_REPO_ROOT="$root"
export COURSE_FAKE_PLAN_JSON_DIR="$tmp_dir/plan-json"
export COURSE_FAKE_MUTATION_LOG="$tmp_dir/mutations.log"
export COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 AWS_REGION=ap-northeast-2

progress="$tmp_dir/evidence/saved-plan-progress.json"
manifest="$tmp_dir/saved-plans.json"
inventory="$tmp_dir/evidence/inventory.json"
invalid_plan_json="$tmp_dir/plan-json/environments__dev__03-platform.json"
cp "$invalid_plan_json" "$tmp_dir/valid-plan.json"
jq '.resource_changes[0].change.actions=["update"]' "$invalid_plan_json" >"$invalid_plan_json.tmp"
mv "$invalid_plan_json.tmp" "$invalid_plan_json"

set +e
output=$(cleanup_apply_saved_plans "$manifest" "$root" "$inventory" "$progress" playdevops 2>&1)
status=$?
set -e
[[ "$status" -ne 0 ]] || { echo 'semantic preflight accepted an update plan' >&2; exit 1; }
grep -Fq 'SAVED_DESTROY_PLAN_NOT_DELETE_ONLY' <<<"$output"
[[ ! -e "$progress" ]] || { echo 'failed semantic preflight created an unrecoverable progress binding' >&2; exit 1; }
[[ ! -s "$tmp_dir/mutations.log" ]] || { echo 'failed semantic preflight allowed mutation' >&2; exit 1; }

mv "$tmp_dir/valid-plan.json" "$invalid_plan_json"
cleanup_apply_saved_plans "$manifest" "$root" "$inventory" "$progress" playdevops
jq -e '.status == "COMPLETE" and (.completed | length) == 8' "$progress" >/dev/null
[[ $(wc -l <"$tmp_dir/mutations.log" | tr -d ' ') -eq 8 ]]

echo 'PASS: semantic preflight failure is recoverable before progress binding'
