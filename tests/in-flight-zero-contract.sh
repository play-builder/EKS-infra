#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/lib/evidence-common.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin" "$tmp_dir/output"

cat >"$tmp_dir/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$PLATFORM_FAKE_AWS_LOG"
[[ "$*" == *"--region $AWS_REGION"* && "$*" == *"--profile $AWS_PROFILE"* ]] || {
  echo 'missing explicit AWS scope' >&2
  exit 98
}
name=
while (($#)); do
  if [[ "$1" == --name ]]; then name=$2; break; fi
  shift
done
[[ "$name" == dev-mini-commerce-eks || "$name" == prod-mini-commerce-eks ]] || exit 97
environment=${name%%-*}
region=$AWS_REGION
account=$AWS_ACCOUNT_ID
owner=$OWNER_ID
[[ "${PLATFORM_FAKE_ARN_REGION_MISMATCH:-}" != "$environment" ]] || region=us-east-1
[[ "${PLATFORM_FAKE_ACCOUNT_MISMATCH:-}" != "$environment" ]] || account=999999999999
[[ "${PLATFORM_FAKE_PLATFORM_MISMATCH:-}" != "$environment" ]] || owner=other-owner
jq -n --arg name "$name" --arg environment "$environment" --arg region "$region" \
  --arg account "$account" --arg owner "$owner" '
  {cluster:{name:$name,status:"ACTIVE",
    arn:("arn:aws:eks:"+$region+":"+$account+":cluster/"+$name),
    endpoint:("https://"+$name+".example.invalid"),
    tags:{OwnerId:$owner,Environment:$environment}}}
'
EOF

cat >"$tmp_dir/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$PLATFORM_FAKE_KUBECTL_LOG"
context=
args=("$@")
for ((index=0; index<${#args[@]}; index++)); do
  if [[ "${args[$index]}" == --context ]]; then context=${args[$((index + 1))]}; fi
done
case "$context" in
  mini-commerce-dev) environment=dev ;;
  mini-commerce-prod) environment=prod ;;
  *) echo 'unexpected context' >&2; exit 97 ;;
esac

if [[ "$*" == *'config view --minify -o json'* ]]; then
  server="https://$environment-mini-commerce-eks.example.invalid"
  [[ "${PLATFORM_FAKE_WRONG_CONTEXT:-}" != "$environment" ]] || server='https://wrong.example.invalid'
  jq -n --arg server "$server" '{clusters:[{cluster:{server:$server}}]}'
elif [[ "$*" == *'api-resources -o name'* ]]; then
  [[ "${PLATFORM_FAKE_API_ERROR:-}" != discovery ]] || exit 96
  printf '%s\n' jobs.batch statefulsets.apps
  if [[ "${PLATFORM_FAKE_OPTIONAL_APIS:-absent}" == present ]]; then
    printf '%s\n' testruns.k6.io podchaos.chaos-mesh.org networkchaos.chaos-mesh.org
  fi
elif [[ "$*" == *'get jobs.batch -A -o json'* ]]; then
  [[ "${PLATFORM_FAKE_API_ERROR:-}" != jobs ]] || exit 96
  case "${PLATFORM_FAKE_WRITER:-none}" in
    load-job) jq -n '{items:[{metadata:{labels:{"playbuilder.io/writer":"load-generator"}},status:{active:1}}]}' ;;
    completed-load-job) jq -n '{items:[{metadata:{labels:{"playbuilder.io/writer":"load-generator"}},status:{active:0,succeeded:1}}]}' ;;
    recovery-job) jq -n '{items:[{metadata:{labels:{"app.kubernetes.io/component":"recovery"}},status:{active:1}}]}' ;;
    migration-job) jq -n '{items:[{metadata:{labels:{"playbuilder.io/writer":"migration"}},status:{active:1}}]}' ;;
    *) jq -n '{items:[]}' ;;
  esac
elif [[ "$*" == *'get statefulsets.apps -A -o json'* ]]; then
  [[ "${PLATFORM_FAKE_API_ERROR:-}" != statefulsets ]] || exit 96
  if [[ "${PLATFORM_FAKE_WRITER:-none}" == recovery-stateful ]]; then
    jq -n '{items:[{metadata:{labels:{"playbuilder.io/cleanup-scope":"recovery"}},spec:{replicas:1}}]}'
  else
    jq -n '{items:[]}'
  fi
elif [[ "$*" == *'get testruns.k6.io -A -o json'* ]]; then
  [[ "${PLATFORM_FAKE_API_ERROR:-}" != k6 ]] || exit 96
  if [[ "${PLATFORM_FAKE_WRITER:-none}" == load-cr ]]; then
    jq -n '{items:[{status:{stage:"running"}}]}'
  else
    jq -n '{items:[]}'
  fi
elif [[ "$*" == *'get podchaos.chaos-mesh.org -A -o json'* || \
        "$*" == *'get networkchaos.chaos-mesh.org -A -o json'* ]]; then
  [[ "${PLATFORM_FAKE_API_ERROR:-}" != chaos ]] || exit 96
  if [[ "${PLATFORM_FAKE_WRITER:-none}" == chaos && "$*" == *'get podchaos.chaos-mesh.org'* ]]; then
    jq -n '{items:[{metadata:{name:"active-chaos"}}]}'
  else
    jq -n '{items:[]}'
  fi
else
  echo "unexpected kubectl: $*" >&2
  exit 97
fi
EOF
chmod +x "$tmp_dir/bin/aws" "$tmp_dir/bin/kubectl"

capture() {
  local output=$1
  shift
  PLATFORM_CHECK_BIN_DIR="$tmp_dir/bin" PLATFORM_FAKE_AWS_LOG="$tmp_dir/aws.log" \
  PLATFORM_FAKE_KUBECTL_LOG="$tmp_dir/kubectl.log" AWS_PROFILE=mini-commerce \
  AWS_REGION=ap-northeast-2 AWS_ACCOUNT_ID=123456789012 OWNER_ID=playbuilder \
    "$@" bash "$root/scripts/capture-in-flight-zero.sh" \
      --dev-context mini-commerce-dev --prod-context mini-commerce-prod \
      --dev-cluster-name dev-mini-commerce-eks --prod-cluster-name prod-mini-commerce-eks \
      --output "$output"
}

: >"$tmp_dir/aws.log"
: >"$tmp_dir/kubectl.log"
valid_output="$tmp_dir/output/valid.json"
capture "$valid_output" env
jq -e '
  keys == ["accountId","clusters","evidenceGrade","expiresAt","observedAt","ownerId","region","remainingWriters","schemaVersion","status"] and
  .schemaVersion == "playbuilder.in-flight-zero/v1" and .evidenceGrade == "STATIC" and .status == "PASS" and
  .ownerId == "playbuilder" and .accountId == "123456789012" and .region == "ap-northeast-2" and
  .clusters == [
    {environment:"dev",context:"mini-commerce-dev",clusterArn:"arn:aws:eks:ap-northeast-2:123456789012:cluster/dev-mini-commerce-eks"},
    {environment:"prod",context:"mini-commerce-prod",clusterArn:"arn:aws:eks:ap-northeast-2:123456789012:cluster/prod-mini-commerce-eks"}] and
  .remainingWriters == {loadGenerators:0,chaosResources:0,recoveryJobs:0,migrationJobs:0} and
  (.observedAt | fromdateiso8601 | todateiso8601) == .observedAt and
  (.expiresAt | fromdateiso8601 | todateiso8601) == .expiresAt and
  (.observedAt | fromdateiso8601) < (.expiresAt | fromdateiso8601)
' "$valid_output" >/dev/null
pb_assert_file_mode "$valid_output" 600
grep -Fq -- '--region ap-northeast-2' "$tmp_dir/aws.log"
grep -Fq -- '--context mini-commerce-dev config view --minify -o json' "$tmp_dir/kubectl.log"
grep -Fq -- '--context mini-commerce-prod config view --minify -o json' "$tmp_dir/kubectl.log"
if grep -Eq 'get (testruns|podchaos|networkchaos)' "$tmp_dir/kubectl.log"; then
  echo 'absent optional writer APIs were queried' >&2
  exit 1
fi

completed_output="$tmp_dir/output/completed-job.json"
capture "$completed_output" env PLATFORM_FAKE_WRITER=completed-load-job
jq -e '[.remainingWriters[]] | all(. == 0)' "$completed_output" >/dev/null

optional_output="$tmp_dir/output/optional-apis.json"
capture "$optional_output" env PLATFORM_FAKE_OPTIONAL_APIS=present
grep -Fq 'get testruns.k6.io -A -o json' "$tmp_dir/kubectl.log"
grep -Fq 'get podchaos.chaos-mesh.org -A -o json' "$tmp_dir/kubectl.log"
grep -Fq 'get networkchaos.chaos-mesh.org -A -o json' "$tmp_dir/kubectl.log"

assert_rejected_without_output() {
  local label=$1
  shift
  local output="$tmp_dir/output/rejected-$label.json"
  set +e
  capture "$output" env "$@" >/dev/null 2>&1
  status=$?
  set -e
  if [[ "$status" -eq 0 || -e "$output" ]]; then
    echo "in-flight capture accepted invalid case: $label" >&2
    exit 1
  fi
}

for writer in load-job load-cr chaos recovery-job recovery-stateful migration-job; do
  if [[ "$writer" == load-cr || "$writer" == chaos ]]; then
    assert_rejected_without_output "$writer" PLATFORM_FAKE_OPTIONAL_APIS=present PLATFORM_FAKE_WRITER="$writer"
  else
    assert_rejected_without_output "$writer" PLATFORM_FAKE_WRITER="$writer"
  fi
done
assert_rejected_without_output wrong-context PLATFORM_FAKE_WRONG_CONTEXT=prod
assert_rejected_without_output wrong-region PLATFORM_FAKE_ARN_REGION_MISMATCH=prod
assert_rejected_without_output wrong-account PLATFORM_FAKE_ACCOUNT_MISMATCH=prod
assert_rejected_without_output wrong-owner PLATFORM_FAKE_PLATFORM_MISMATCH=prod
assert_rejected_without_output discovery-error PLATFORM_FAKE_API_ERROR=discovery
assert_rejected_without_output jobs-error PLATFORM_FAKE_API_ERROR=jobs
assert_rejected_without_output optional-api-error PLATFORM_FAKE_OPTIONAL_APIS=present PLATFORM_FAKE_API_ERROR=k6

identity_output="$tmp_dir/output/existing-identity.json"
capture "$identity_output" env
jq '.ownerId="other-owner"' "$identity_output" >"$tmp_dir/other.json"
mv "$tmp_dir/other.json" "$identity_output"
before=$(shasum -a 256 "$identity_output")
set +e
capture "$identity_output" env >/dev/null 2>&1
status=$?
set -e
after=$(shasum -a 256 "$identity_output")
if [[ "$status" -eq 0 || "$before" != "$after" ]]; then
  echo 'existing evidence identity was overwritten' >&2
  exit 1
fi

canonical="$root/evidence/cleanup/in-flight-zero.json"
set +e
capture "$canonical" env >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -eq 0 || -e "$canonical" ]]; then
  echo 'fixture adapter wrote the canonical runtime evidence path' >&2
  exit 1
fi

set +e
AWS_PROFILE=mini-commerce AWS_REGION=ap-northeast-2 AWS_ACCOUNT_ID=123456789012 OWNER_ID=playbuilder \
  bash "$root/scripts/capture-in-flight-zero.sh" \
    --dev-context mini-commerce-dev --prod-context mini-commerce-prod \
    --dev-cluster-name dev-mini-commerce-eks --prod-cluster-name prod-mini-commerce-eks \
    --output "$tmp_dir/output/runtime-override.json" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -eq 0 || -e "$tmp_dir/output/runtime-override.json" ]]; then
  echo 'runtime capture accepted a caller-selected output path' >&2
  exit 1
fi

echo 'PASS: in-flight zero live identity and writer contract'
