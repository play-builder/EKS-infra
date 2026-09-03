#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/cleanup-fixture-helpers.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin" "$tmp_dir/evidence"
prepare_cleanup_fixtures "$root" "$tmp_dir/evidence" ap-northeast-2

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

common=(
  --approval "$root/tests/fixtures/checkpoint-approved-destroy.json"
  --inventory "$tmp_dir/evidence/inventory.json"
  --retain-decisions "$tmp_dir/evidence/decisions.json"
  --output "$tmp_dir/resume.json"
)

COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_FAKE_MUTATION_LOG="$tmp_dir/mutations.log" COURSE_FAKE_AWS_LOG="$tmp_dir/aws.log" \
  bash "$root/scripts/checkpoint-teardown.sh" "${common[@]}"
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
! grep -Eq 'state-backend|iam-github-oidc|snapshot|ecr|secret' "$tmp_dir/mutations.log"

echo 'PASS: guarded checkpoint partial teardown and resume contract'
