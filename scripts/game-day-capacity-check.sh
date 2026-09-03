#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/evidence-common.sh"

if [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then
  [[ -d "$COURSE_CHECK_BIN_DIR" ]] || course_fail 'COURSE_CHECK_BIN_DIR is not a directory' 64
  PATH="$COURSE_CHECK_BIN_DIR:$PATH"
fi

context=''
profile=''
output=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context) context=${2:-}; shift 2 ;;
    --profile|--input) profile=${2:-}; shift 2 ;;
    --output) output=${2:-}; shift 2 ;;
    --help|-h)
      printf '%s\n' 'usage: game-day-capacity-check.sh [--context <kubectl-context>] --profile <ch17-profile.json> --output <file>'
      exit 0
      ;;
    *)
      # Keep the Ch17/Ch25 shell interface convenient for course labs.
      if [[ -z "$context" ]]; then context=$1
      elif [[ -z "$profile" ]]; then profile=$1
      elif [[ -z "$output" ]]; then output=$1
      else course_fail "unknown argument: $1" 64
      fi
      shift
      ;;
  esac
done

[[ -n "$context" && -n "$profile" && -n "$output" ]] || \
  course_fail 'usage: game-day-capacity-check.sh <kubectl-context> <ch17-profile.json> <output.json>' 64
for command in aws kubectl jq; do command -v "$command" >/dev/null 2>&1 || course_fail "required command not found: $command" 127; done
for name in AWS_PROFILE AWS_REGION; do [[ -n "${!name:-}" ]] || course_fail "$name is required" 64; done
course_validate_region "$AWS_REGION"
course_require_file "$profile"
[[ -d "$(dirname -- "$output")" ]] || course_fail "output directory not found: $(dirname -- "$output")" 66

course_assert_json "$profile" '
  .accountId as $accountId |
  keys == ["accountId","billable","clusterArn","courseId","expiresAt","region","reserve","rollout","schemaVersion","subnetIds","workload"] and
  .schemaVersion == "course.prod-live-capacity-profile/v1" and
  (.courseId | type == "string" and length > 0) and
  (.accountId | test("^[0-9]{12}$")) and
  .region == $ENV.AWS_REGION and
  (.clusterArn | test("^arn:aws:eks:" + $ENV.AWS_REGION + ":" + $accountId + ":cluster/[A-Za-z0-9][A-Za-z0-9_-]+$")) and
  (.subnetIds | type == "array" and length >= 1 and all(test("^subnet-[A-Za-z0-9-]+$"))) and
  (.reserve | keys == ["cpuMilli","memoryMiB","pods"]) and
  (.workload | keys == ["cpuMilliPerPod","memoryMiBPerPod","podsPerReplica","replicas"]) and
  (.rollout | keys == ["maxSurgePods"]) and
  (.billable | keys == ["estimatedMonthlyUsd","limitMonthlyUsd"]) and
  ([.reserve[],.workload[],.rollout[],.billable[]] | all(type == "number" and . >= 0)) and
  .workload.replicas > 0 and .workload.podsPerReplica > 0 and
  now < (.expiresAt | fromdateiso8601)
' 'invalid or expired Ch17 capacity profile'

subnet_ids=()
while IFS= read -r subnet_id; do subnet_ids+=("$subnet_id"); done < <(jq -r '.subnetIds[]' "$profile")

# These are deliberately fresh API reads. A fixture can stand in for the CLI
# in a contract test, but omitting either query is never allowed to become a
# live result.
nodes=$(kubectl --context "$context" get nodes -o json) || course_fail 'kubectl node allocatable query failed'
daemonsets=$(kubectl --context "$context" -n kube-system get daemonsets -o json) || course_fail 'kubectl DaemonSet query failed'
subnets=$(aws ec2 describe-subnets --subnet-ids "${subnet_ids[@]}" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" --output json) || course_fail 'AWS subnet capacity query failed'

node_shape=$(jq '
  def cpu_m:
    if type == "number" then . * 1000
    elif endswith("m") then rtrimstr("m") | tonumber
    else tonumber * 1000 end;
  def mem_mib:
    if type == "number" then .
    elif endswith("Ki") then (rtrimstr("Ki") | tonumber) / 1024
    elif endswith("Mi") then rtrimstr("Mi") | tonumber
    elif endswith("Gi") then (rtrimstr("Gi") | tonumber) * 1024
    else error("unsupported memory quantity") end;
  if (.items | length) == 0 then error("no nodes") else {
    count:(.items | length),
    totalCpuMilli:([.items[].status.allocatable.cpu | cpu_m] | add | floor),
    totalMemoryMiB:([.items[].status.allocatable.memory | mem_mib] | add | floor),
    totalPodSlots:([.items[].status.allocatable.pods | tonumber] | add),
    minMaxPodsPerNode:([.items[].status.allocatable.pods | tonumber] | min)
  } end
' <<<"$nodes") || course_fail 'invalid node allocatable response'

daemon_shape=$(jq '
  def cpu_m:
    if . == null then 0 elif type == "number" then . * 1000
    elif endswith("m") then rtrimstr("m") | tonumber else tonumber * 1000 end;
  def mem_mib:
    if . == null then 0 elif type == "number" then .
    elif endswith("Ki") then (rtrimstr("Ki") | tonumber) / 1024
    elif endswith("Mi") then rtrimstr("Mi") | tonumber
    elif endswith("Gi") then (rtrimstr("Gi") | tonumber) * 1024
    else error("unsupported memory quantity") end;
  reduce .items[] as $ds ({cpuMilli:0,memoryMiB:0,pods:0};
    ($ds.status.desiredNumberScheduled // 0) as $count |
    .cpuMilli += ($count * ([$ds.spec.template.spec.containers[]? | (.resources.requests.cpu // null) | cpu_m] | add // 0)) |
    .memoryMiB += ($count * ([$ds.spec.template.spec.containers[]? | (.resources.requests.memory // null) | mem_mib] | add // 0)) |
    .pods += $count
  ) | .memoryMiB |= floor
' <<<"$daemonsets") || course_fail 'invalid DaemonSet response'

subnet_available=$(jq -r --argjson expected "$(jq '.subnetIds' "$profile")" '
  . as $response |
  if ($expected | all(. as $id | any($response.Subnets[]; .SubnetId == $id)))
  then ([$response.Subnets[] | select(.SubnetId as $id | $expected | index($id)) | .AvailableIpAddressCount] | add)
  else error("missing subnet") end
' <<<"$subnets") || course_fail 'invalid or incomplete subnet response'
[[ "$subnet_available" =~ ^[0-9]+$ ]] || course_fail 'subnet available IP count is not numeric'

observed_at=$(course_now)
capacity_input=$(jq -n --argjson profile "$(jq -c . "$profile")" --argjson nodes "$node_shape" \
  --argjson daemon "$daemon_shape" --arg subnet "$subnet_available" --arg observed "$observed_at" '
  {
    schemaVersion:"course.capacity-input/v1", evidenceGrade:"STATIC", mode:"live",
    courseId:$profile.courseId, accountId:$profile.accountId, region:$profile.region,
    nodes:$nodes, reserve:$profile.reserve, daemonSets:$daemon,
    workload:$profile.workload, rollout:$profile.rollout,
    network:{subnetAvailableIps:($subnet|tonumber)}, billable:$profile.billable,
    observedAt:$observed, expiresAt:$profile.expiresAt
  }')

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
printf '%s\n' "$capacity_input" >"$tmp_dir/capacity-input.json"
set +e
COURSE_CHECK_DETAIL_ONLY=true bash "$SCRIPT_DIR/capacity-check.sh" --mode live \
  --input "$tmp_dir/capacity-input.json" --output "$tmp_dir/capacity-decision.json" >"$tmp_dir/capacity.stdout" 2>"$tmp_dir/capacity.stderr"
status=$?
set -e
if [[ "$status" -ne 0 ]]; then
  cat "$tmp_dir/capacity.stderr" >&2
  exit "$status"
fi

decision=$(jq -r '.decision' "$tmp_dir/capacity-decision.json")
[[ "$decision" == "GO" ]] || {
  echo 'NO_GO: current cluster capacity is insufficient for the bounded game day.' >&2
  exit 2
}

grade=$(course_runtime_grade)
payload=$(jq -n --arg grade "$grade" --arg context "$context" --arg observed "$observed_at" \
  --arg profile_sha "$(course_sha256_file "$profile")" \
  --arg decision_sha "$(course_sha256_file "$tmp_dir/capacity-decision.json")" \
  --argjson profile "$(jq -c . "$profile")" --argjson nodes "$node_shape" --argjson daemon "$daemon_shape" \
  --arg subnet "$subnet_available" --arg decision "$decision" '
  {
    schemaVersion:"course.game-day-capacity/v1", evidenceGrade:$grade, decision:$decision,
    courseId:$profile.courseId, accountId:$profile.accountId, region:$profile.region,
    clusterArn:$profile.clusterArn, kubectlContext:$context,
    bindings:{profileSha256:$profile_sha,capacityDecisionSha256:$decision_sha},
    observations:{nodes:$nodes,daemonSets:$daemon,subnetAvailableIps:($subnet|tonumber)},
    observedAt:$observed, expiresAt:$profile.expiresAt
  }
')
course_write_json "$output" "$payload"
if [[ "$grade" == "STATIC" ]]; then
  [[ "${COURSE_CHECK_DETAIL_ONLY:-false}" == true ]] || echo 'PASS: [STATIC] SIMULATED_CLOUD_CONTRACT Ch25 live capacity recheck is GO.'
else
  [[ "${COURSE_CHECK_DETAIL_ONLY:-false}" == true ]] || echo 'PASS: [CLOUD_RUNTIME] Ch25 live capacity recheck is GO.'
fi
