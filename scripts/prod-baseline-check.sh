#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/evidence-common.sh"

if [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then
  [[ -d "$COURSE_CHECK_BIN_DIR" ]] || course_fail 'COURSE_CHECK_BIN_DIR is not a directory' 64
  PATH="$COURSE_CHECK_BIN_DIR:$PATH"
fi

[[ $# -eq 3 || $# -eq 4 ]] || course_fail 'usage: prod-baseline-check.sh <kubectl-context> <namespace> <rollout-name> [output.json]' 64
context=$1
namespace=$2
rollout_name=$3
output=${4:-}
: "${AWS_REGION:?AWS_REGION is required}"
: "${AWS_ACCOUNT_ID:?AWS_ACCOUNT_ID is required}"
course_validate_region "$AWS_REGION"
course_validate_account "$AWS_ACCOUNT_ID"
[[ "$namespace" == prod ]] || course_fail 'baseline namespace must be prod' 64

rollout=$(kubectl --context "$context" -n "$namespace" get rollout "$rollout_name" -o json)
replicasets=$(kubectl --context "$context" -n "$namespace" get replicasets -o json)
analysisruns=$(kubectl --context "$context" -n "$namespace" get analysisruns -o json)

jq -e --arg name "$rollout_name" '
  .kind == "Rollout" and .metadata.name == $name and (.metadata.uid | type == "string" and length > 0) and
  .status.phase == "Healthy" and (.status.stableRS | type == "string" and length > 0) and
  .status.stableRS == .status.currentPodHash and
  .spec.replicas > 0 and .status.replicas == .spec.replicas and
  .status.readyReplicas == .spec.replicas and .status.availableReplicas == .spec.replicas
' <<<"$rollout" >/dev/null || course_fail 'PROD_BASELINE_ROLLOUT_NOT_HEALTHY'

rollout_uid=$(jq -r '.metadata.uid' <<<"$rollout")
stable_hash=$(jq -r '.status.stableRS' <<<"$rollout")
desired=$(jq -r '.spec.replicas' <<<"$rollout")
stable_rs=$(jq -c --arg uid "$rollout_uid" --arg name "$rollout_name" --arg hash "$stable_hash" '
  [.items[] | select(
    .metadata.labels["rollouts-pod-template-hash"] == $hash and
    .metadata.annotations["rollout.argoproj.io/revision"] == "1" and
    any(.metadata.ownerReferences[]?; .kind == "Rollout" and .name == $name and .uid == $uid and .controller == true)
  )] | if length == 1 then .[0] else empty end
' <<<"$replicasets")
[[ -n "$stable_rs" ]] || course_fail 'PROD_BASELINE_STABLE_RS_NOT_UNIQUE'
jq -e --argjson desired "$desired" '
  .spec.replicas == $desired and .status.replicas == $desired and
  .status.readyReplicas == $desired and .status.availableReplicas == $desired
' <<<"$stable_rs" >/dev/null || course_fail 'PROD_BASELINE_STABLE_RS_NOT_READY'

started=$(jq --arg uid "$rollout_uid" --arg name "$rollout_name" '
  [.items[] | select(
    any(.metadata.ownerReferences[]?; .kind == "Rollout" and .name == $name and .uid == $uid) or
    .metadata.labels["rollouts.argoproj.io/rollout-name"] == $name
  )] | length
' <<<"$analysisruns")
[[ "$started" -eq 0 ]] || course_fail 'PROD_BASELINE_ANALYSIS_ALREADY_STARTED'

grade=$(course_runtime_grade)
observed_at=$(course_now)
payload=$(jq -n --arg grade "$grade" --arg region "$AWS_REGION" --arg context "$context" \
  --arg namespace "$namespace" --arg rollout "$rollout_name" --arg uid "$rollout_uid" \
  --arg hash "$stable_hash" --arg observed "$observed_at" --argjson replicas "$desired" '
  {
    schemaVersion:"course.prod-baseline/v1", evidenceGrade:$grade, status:"HEALTHY", region:$region,
    kubectlContext:$context, namespace:$namespace, rolloutName:$rollout, rolloutUid:$uid,
    stablePodHash:$hash, stableRevision:1, replicas:$replicas, analysisRunsStarted:0, observedAt:$observed
  }
')
[[ -z "$output" ]] || course_write_json "$output" "$payload"
[[ -n "$output" ]] || printf '%s\n' "$payload"
if [[ "$grade" == STATIC ]]; then
  echo 'PASS: [STATIC] SIMULATED_CLOUD_CONTRACT Prod baseline Rollout is Healthy at revision 1.'
else
  echo 'PASS: [CLOUD_RUNTIME] Prod baseline Rollout is Healthy at revision 1.'
fi
