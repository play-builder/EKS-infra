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
elif [[ "$1" == "api" ]]; then
  endpoint=${!#}
  case "$endpoint" in
    repos/owner/EKS-infra|repos/owner/cicd-course-sample-app)
      repository_name=${endpoint##*/}
      jq -n --arg name "$repository_name" '{owner:{login:"owner",id:101},name:$name,id:202}'
      ;;
    repos/owner/EKS-infra/actions/oidc/customization/sub|repos/owner/cicd-course-sample-app/actions/oidc/customization/sub)
      echo '{"use_immutable_subject":true}'
      ;;
    repos/owner/argocd-gitops/rulesets)
      echo '[{"id":42,"name":"main-protection","enforcement":"active","target":"branch"}]'
      ;;
    repos/owner/argocd-gitops/rulesets/42)
      echo '{"bypass_actors":[],"rules":[{"type":"pull_request","parameters":{"require_code_owner_review":true}},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"validate"}]}}]}'
      ;;
    *)
      printf 'unexpected gh api endpoint: %s\n' "$endpoint" >&2
      exit 97
      ;;
  esac
else
  printf 'unexpected gh invocation: %q ' "$@" >&2
  exit 97
fi
EOF

cat >"$tmp_dir/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
: "${COURSE_FAKE_AWS_LOG:?}"
printf '%s\n' "$*" >>"$COURSE_FAKE_AWS_LOG"
case "$1 $2" in
  's3api get-bucket-tagging')
    echo '{"TagSet":[{"Key":"ManagedBy","Value":"gitops-course"},{"Key":"Project","Value":"course"}]}'
    ;;
  's3api get-bucket-location')
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
      echo '{"LocationConstraint":null}'
    else
      jq -n --arg region "$AWS_REGION" '{LocationConstraint:$region}'
    fi
    ;;
  's3api get-bucket-versioning') echo '{"Status":"Enabled"}' ;;
  's3api get-bucket-encryption')
    echo '{"ServerSideEncryptionConfiguration":{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}}'
    ;;
  's3api get-public-access-block')
    echo '{"PublicAccessBlockConfiguration":{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}}'
    ;;
  'route53 get-hosted-zone')
    echo '{"DelegationSet":{"NameServers":["ns-1.example.net.","ns-2.example.net."]}}'
    ;;
  'iam list-open-id-connect-providers')
    echo '{"OpenIDConnectProviderList":[{"Arn":"arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"}]}'
    ;;
  'iam get-open-id-connect-provider')
    echo '{"Url":"token.actions.githubusercontent.com","ClientIDList":["sts.amazonaws.com"]}'
    ;;
  *)
    printf 'unexpected aws invocation: %s\n' "$*" >&2
    exit 97
    ;;
esac
EOF

cat >"$tmp_dir/bin/dig" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' ns-1.example.net. ns-2.example.net.
EOF
chmod +x "$tmp_dir/bin/gh" "$tmp_dir/bin/aws" "$tmp_dir/bin/dig"

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

for region in ap-northeast-2 us-east-1; do
  aws_log="$tmp_dir/aws-ch02-$region.log"
  : >"$aws_log"
  COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_FAKE_AWS_LOG="$aws_log" \
    AWS_PROFILE=course AWS_REGION="$region" STATE_BUCKET_NAME=course-state LAB_PROJECT_NAME=course \
    HOSTED_ZONE_ID=Z123 ROOT_DOMAIN=example.com INFRA_GH_REPO=owner/EKS-infra \
    APP_GH_REPO=owner/cicd-course-sample-app GITOPS_GH_REPO=owner/argocd-gitops \
    bash "$root/scripts/course-check.sh" ch02 >"$tmp_dir/ch02-$region.out"
  [[ $(grep -Ec 'PASS: \[STATIC\]' "$tmp_dir/ch02-$region.out") -eq 1 ]]
  [[ $(wc -l <"$aws_log" | tr -d ' ') -eq 8 ]]
  while IFS= read -r invocation; do
    if [[ " $invocation " != *" --region $region "* ]]; then
      printf 'AWS lookup omitted selected Region: %s\n' "$invocation" >&2
      exit 1
    fi
  done <"$aws_log"
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
