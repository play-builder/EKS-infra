#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/evidence-common.sh"

mode=''
input=''
output=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) mode=${2:-}; shift 2 ;;
    --input) input=${2:-}; shift 2 ;;
    --output) output=${2:-}; shift 2 ;;
    *) course_fail "unknown argument: $1" 64 ;;
  esac
done
[[ "$mode" == design || "$mode" == estimate || "$mode" == live ]] || course_fail 'mode must be design, estimate, or live' 64
[[ -n "$input" ]] || course_fail '--input is required' 64
course_require_file "$input"
course_assert_canonical_utc_seconds "$input" 'capacity input timestamps' \
  '["observedAt"]' '["expiresAt"]'

CAPACITY_MODE="$mode" course_assert_json "$input" '
  keys == ["accountId","billable","courseId","daemonSets","evidenceGrade","expiresAt","mode","network","nodes","observedAt","region","reserve","rollout","schemaVersion","workload"] and
  .schemaVersion == "course.capacity-input/v1" and .evidenceGrade == "STATIC" and .mode == $ENV.CAPACITY_MODE and
  (.courseId | type == "string" and length > 0) and (.accountId | test("^[0-9]{12}$")) and
  (.region == "ap-northeast-2" or .region == "us-east-1") and
  (.nodes | keys == ["count","minMaxPodsPerNode","totalCpuMilli","totalMemoryMiB","totalPodSlots"]) and
  (.reserve | keys == ["cpuMilli","memoryMiB","pods"]) and
  (.daemonSets | keys == ["cpuMilli","memoryMiB","pods"]) and
  (.workload | keys == ["cpuMilliPerPod","memoryMiBPerPod","podsPerReplica","replicas"]) and
  (.rollout | keys == ["maxSurgePods"]) and
  (.network | keys == ["subnetAvailableIps"]) and
  (.billable | keys == ["estimatedMonthlyUsd","limitMonthlyUsd"]) and
  ([.nodes[],.reserve[],.daemonSets[],.workload[],.rollout[],.network[]] | all(type == "number" and floor == . and . >= 0)) and
  ([.billable[]] | all(type == "number" and . >= 0)) and
  .nodes.count > 0 and .nodes.minMaxPodsPerNode > 0 and .workload.replicas > 0 and .workload.podsPerReplica > 0 and
  (.observedAt | fromdateiso8601) <= now and now < (.expiresAt | fromdateiso8601)
' 'invalid or non-exact capacity input'

result=$(jq --arg mode "$mode" '
  (.workload.replicas + .rollout.maxSurgePods) as $peak |
  {
    schemaVersion:"course.capacity-decision/v1",
    evidenceGrade:"STATIC",
    mode:$mode,
    courseId:.courseId,
    accountId:.accountId,
    region:.region,
    decision:(if
      (.nodes.totalCpuMilli - .reserve.cpuMilli - .daemonSets.cpuMilli) >= ($peak * .workload.cpuMilliPerPod) and
      (.nodes.totalMemoryMiB - .reserve.memoryMiB - .daemonSets.memoryMiB) >= ($peak * .workload.memoryMiBPerPod) and
      (.nodes.totalPodSlots - .reserve.pods - .daemonSets.pods) >= ($peak * .workload.podsPerReplica) and
      .network.subnetAvailableIps >= ($peak * .workload.podsPerReplica + .nodes.count) and
      .billable.estimatedMonthlyUsd <= .billable.limitMonthlyUsd
      then "GO" else "NO_GO" end),
    peakReplicas:$peak,
    required:{
      cpuMilli:($peak * .workload.cpuMilliPerPod),
      memoryMiB:($peak * .workload.memoryMiBPerPod),
      pods:($peak * .workload.podsPerReplica),
      subnetIps:($peak * .workload.podsPerReplica + .nodes.count)
    },
    available:{
      cpuMilli:(.nodes.totalCpuMilli - .reserve.cpuMilli - .daemonSets.cpuMilli),
      memoryMiB:(.nodes.totalMemoryMiB - .reserve.memoryMiB - .daemonSets.memoryMiB),
      pods:(.nodes.totalPodSlots - .reserve.pods - .daemonSets.pods),
      subnetIps:.network.subnetAvailableIps
    },
    billable:.billable,
    observedAt:.observedAt,
    expiresAt:.expiresAt
  }
' "$input")

[[ -z "$output" ]] || course_write_json "$output" "$result"
printf '%s\n' "$result"
if [[ $(jq -r '.decision' <<<"$result") != GO ]]; then
  echo 'NO_GO: CPU, memory, pod, subnet IP, or cost headroom is insufficient.' >&2
  exit 2
fi
[[ "${COURSE_CHECK_DETAIL_ONLY:-false}" == true ]] || echo 'PASS: [STATIC] capacity arithmetic is GO.'
