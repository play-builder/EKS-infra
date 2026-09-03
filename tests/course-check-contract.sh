#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixtures="$root/tests/fixtures"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$1 $2" == "run list" ]]; then
  cat "$COURSE_CHECK_RUNS_FIXTURE"
elif [[ "$1 $2" == "run watch" ]]; then
  exit 0
elif [[ "$1 $2" == "run view" ]]; then
  run_id=$3
  jq --argjson id "$run_id" --arg sha "$COURSE_CHECK_HEAD_SHA" --arg workflow "${COURSE_CHECK_WORKFLOW_NAME:-CI}" '
    {databaseId:$id,headSha:$sha,workflowName:$workflow,event:"push",status:"completed",conclusion:"success",url:"https://example.invalid/run/\($id)"}
  ' <<<'{}'
else
  printf 'unexpected gh invocation: %q ' "$@" >&2
  exit 97
fi
EOF
chmod +x "$tmp_dir/bin/gh"

sha=0123456789abcdef0123456789abcdef01234567

run_case() {
  local fixture=$1 expected_status=$2 expected_text=$3 output status
  set +e
  output=$(COURSE_CHECK_BIN_DIR="$tmp_dir/bin" \
    COURSE_CHECK_RUNS_FIXTURE="$fixtures/$fixture" \
    COURSE_CHECK_HEAD_SHA="$sha" \
    COURSE_CHECK_WAIT_ATTEMPTS=1 \
    bash "$root/scripts/course-check.sh" ch05 owner/repo "$sha" CI push 100 2>&1)
  status=$?
  set -e
  [[ "$status" -eq "$expected_status" ]]
  grep -Fq "$expected_text" <<<"$output"
  if [[ "$expected_status" -eq 0 ]]; then
    [[ $(grep -Ec 'PASS: \[(STATIC|CLOUD_RUNTIME|INCIDENT_EVIDENCE)\]' <<<"$output") -eq 1 ]]
    grep -Fq '[STATIC] SIMULATED_CLOUD_CONTRACT' <<<"$output"
    ! grep -Fq '[CLOUD_RUNTIME]' <<<"$output"
  fi
}

run_case workflow-runs-one-exact.json 0 'databaseId'
run_case workflow-runs-none.json 1 'EXACT_RUN_NOT_FOUND'
run_case workflow-runs-ambiguous.json 1 'AMBIGUOUS_RUN'

default_workflow_output=$(COURSE_CHECK_BIN_DIR="$tmp_dir/bin" \
  COURSE_CHECK_RUNS_FIXTURE="$fixtures/workflow-runs-one-exact-lowercase.json" \
  COURSE_CHECK_HEAD_SHA="$sha" COURSE_CHECK_WORKFLOW_NAME=ci \
  COURSE_CHECK_WAIT_ATTEMPTS=1 \
  bash "$root/scripts/course-check.sh" ch05 owner/repo "$sha")
grep -Fq 'databaseId' <<<"$default_workflow_output"
grep -Fq '[STATIC] SIMULATED_CLOUD_CONTRACT' <<<"$default_workflow_output"

grep -Fq 'OTEL_EXPORTER_OTLP_ENDPOINT' "$root/README.md"
! grep -Fq 'OTEL_EXPORTER_OTLP_TRACES_ENDPOINT' "$root/README.md"

for region in ap-northeast-2 us-east-1; do
  AWS_REGION=$region COURSE_CHECK_BIN_DIR="$tmp_dir/bin" \
    bash "$root/scripts/course-check.sh" ch14 --contract-only >"$tmp_dir/ch14-$region.out"
  [[ $(grep -Ec 'PASS: \[STATIC\]' "$tmp_dir/ch14-$region.out") -eq 1 ]]
done

while IFS=$'\t' read -r chapter mode; do
  [[ -n "$chapter" ]] || continue
  case "$mode" in
    contract)
      AWS_REGION=ap-northeast-2 COURSE_CHECK_BIN_DIR="$tmp_dir/bin" \
        bash "$root/scripts/course-check.sh" "$chapter" --contract-only >/dev/null
      ;;
    workflow)
      COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_CHECK_RUNS_FIXTURE="$fixtures/workflow-runs-one-exact.json" \
        COURSE_CHECK_HEAD_SHA="$sha" COURSE_CHECK_WAIT_ATTEMPTS=1 \
        bash "$root/scripts/course-check.sh" "$chapter" owner/repo "$sha" CI push 100 >/dev/null
      ;;
  esac
done < <(jq -r '.chapters[] | [.chapter,.mode] | @tsv' "$fixtures/chapter-command-contracts.json")

echo 'PASS: course-check semantic dispatcher contract'
