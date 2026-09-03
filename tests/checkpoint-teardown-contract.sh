#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/cleanup-fixture-helpers.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin" "$tmp_dir/evidence"
prepare_cleanup_fixtures "$root" "$tmp_dir/evidence" ap-northeast-2
prepare_saved_plan_manifest "$tmp_dir/plans" "$tmp_dir/saved-plans.json"

cat >"$tmp_dir/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$COURSE_FAKE_MUTATION_LOG"
EOF
cat >"$tmp_dir/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$COURSE_FAKE_AWS_LOG"
printf '{"Account":"123456789012"}\n'
EOF
chmod +x "$tmp_dir/bin/terraform" "$tmp_dir/bin/aws"
: >"$tmp_dir/mutations.log"
: >"$tmp_dir/aws.log"

approval="$root/tests/fixtures/checkpoint-approved-destroy.json"
common_without_approval=(
  --saved-plan-manifest "$tmp_dir/saved-plans.json"
  --inventory "$tmp_dir/evidence/inventory.json"
  --retain-decisions "$tmp_dir/evidence/decisions.json"
  --output "$tmp_dir/resume.json"
)
common=(--approval "$approval" "${common_without_approval[@]}")

expect_timestamp_rejected_before_mutation() {
  local label=$1 field=$2 value=$3 status
  local candidate="$tmp_dir/approval-$label.json"
  jq --arg field "$field" --arg value "$value" '.[$field]=$value' "$approval" >"$candidate"
  : >"$tmp_dir/mutations.log"
  : >"$tmp_dir/aws.log"
  rm -f -- "$tmp_dir/resume.json"
  set +e
  COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_FAKE_MUTATION_LOG="$tmp_dir/mutations.log" COURSE_FAKE_AWS_LOG="$tmp_dir/aws.log" \
  AWS_PROFILE=course \
    bash "$root/scripts/checkpoint-teardown.sh" --approval "$candidate" "${common_without_approval[@]}" --execute \
      --confirm-account-id 123456789012 --confirm-region ap-northeast-2 --confirm-course-id course-2026 \
      >/dev/null 2>&1
  status=$?
  set -e
  if [[ "$status" -eq 0 || -s "$tmp_dir/aws.log" || -s "$tmp_dir/mutations.log" || -e "$tmp_dir/resume.json" ]]; then
    echo "expected $label timestamp rejection before cloud or mutation calls" >&2
    exit 1
  fi
}

expect_timestamp_rejected_before_mutation approved-invalid-calendar approvedAt '2020-02-30T00:00:00Z'
expect_timestamp_rejected_before_mutation approved-fractional approvedAt '2020-03-01T00:00:00.123Z'
expect_timestamp_rejected_before_mutation approved-offset approvedAt '2020-03-01T09:00:00+09:00'
expect_timestamp_rejected_before_mutation expires-invalid-calendar expiresAt '2099-02-31T00:00:00Z'
expect_timestamp_rejected_before_mutation expires-fractional expiresAt '2099-03-01T00:00:00.123Z'
expect_timestamp_rejected_before_mutation expires-offset expiresAt '2099-03-01T09:00:00+09:00'

: >"$tmp_dir/mutations.log"
: >"$tmp_dir/aws.log"

COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_FAKE_MUTATION_LOG="$tmp_dir/mutations.log" COURSE_FAKE_AWS_LOG="$tmp_dir/aws.log" \
  bash "$root/scripts/course-check.sh" ch26 --checkpoint-teardown "${common[@]}"
[[ ! -s "$tmp_dir/mutations.log" && ! -e "$tmp_dir/resume.json" ]]

set +e
COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_FAKE_MUTATION_LOG="$tmp_dir/mutations.log" COURSE_FAKE_AWS_LOG="$tmp_dir/aws.log" \
AWS_PROFILE=course \
  bash "$root/scripts/checkpoint-teardown.sh" "${common[@]}" --execute \
    --confirm-account-id 123456789012 --confirm-region ap-northeast-2 >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -eq 0 || -s "$tmp_dir/mutations.log" ]]; then
  echo 'missing course confirmation must fail before mutation' >&2
  exit 1
fi

COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_FAKE_MUTATION_LOG="$tmp_dir/mutations.log" COURSE_FAKE_AWS_LOG="$tmp_dir/aws.log" \
AWS_PROFILE=course \
  bash "$root/scripts/checkpoint-teardown.sh" "${common[@]}" --execute \
    --confirm-account-id 123456789012 --confirm-region ap-northeast-2 --confirm-course-id course-2026

jq -e '
  keys == ["accountId","courseId","dependencyOrder","evidenceGrade","flags","observedAt","region","retained","schemaVersion","stateKeys","status","versions"] and
  .schemaVersion == "course.checkpoint-resume/v1" and .status == "PARTIAL_TEARDOWN" and
  (.retained | length == 3) and all(.retained[]; .decision? == null and (.owner | length > 0) and (.followUpAction | length > 0))
' "$tmp_dir/resume.json" >/dev/null
[[ $(wc -l <"$tmp_dir/mutations.log" | tr -d ' ') -eq 8 ]]
expected='environments/prod/04-workloads/argocd environments/dev/04-workloads/argocd environments/prod/03-platform environments/dev/03-platform environments/prod/02-eks environments/dev/02-eks environments/prod/01-network environments/dev/01-network'
actual=$(sed -E 's/^-chdir=([^ ]+) .*/\1/' "$tmp_dir/mutations.log" | sed "s#^$root/##" | paste -sd' ' -)
[[ "$actual" == "$expected" ]]
while IFS= read -r saved_plan; do
  grep -Fq "apply $saved_plan" "$tmp_dir/mutations.log"
done < <(jq -r '.plans[].path' "$tmp_dir/saved-plans.json")
! grep -Eq 'state-backend|iam-github-oidc|snapshot|ecr|secret' "$tmp_dir/mutations.log"

echo 'PASS: guarded checkpoint partial teardown and resume contract'
