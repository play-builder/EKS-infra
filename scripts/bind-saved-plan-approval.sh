#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source "$script_dir/lib/evidence-common.sh"

artifact_dir=${1:?artifact directory is required}
review_history=${2:?review history JSON is required}
environment=${3:?environment is required}
request_identity=${4:?request identity is required}
run_id=${5:?workflow run ID is required}
manifest="$artifact_dir/plan-identity.json"
course_require_file "$manifest"
course_require_file "$review_history"
[[ "$request_identity" =~ [^[:space:]] && "$request_identity" != pending ]] || \
  course_fail SAVED_PLAN_APPROVAL_HISTORY_INVALID
[[ "$run_id" =~ ^[1-9][0-9]*$ ]] || course_fail SAVED_PLAN_APPROVAL_HISTORY_INVALID

# Preserve the requester captured when the plan was created. An apply-only rerun
# by another actor cannot rebind that artifact to itself.
jq -e --arg requester "$request_identity" '.requestIdentity == $requester' \
  "$manifest" >/dev/null || course_fail SAVED_PLAN_REQUEST_IDENTITY_MISMATCH

approval_identity=$(jq -er --arg environment "$environment" --arg requester "$request_identity" '
  [ .[] |
    select(.state == "approved") |
    select(any(.environments[]?; .name == $environment)) |
    .user.login |
    select(type == "string" and test("[^[:space:]\\uFEFF]")) |
    select(ascii_downcase != ($requester | ascii_downcase))
  ] | unique | if length == 1 then .[0] else error("approval history must have one distinct non-self approver") end
' "$review_history" 2>/dev/null) || course_fail SAVED_PLAN_APPROVAL_HISTORY_INVALID

jq -n --arg environment "$environment" --arg run "$run_id" --arg requester "$request_identity" \
  --arg approver "$approval_identity" '
  {schemaVersion:"platform.saved-plan-approval/v1",source:"github-actions-review-history",
   environment:$environment,state:"approved",runId:$run,requestIdentity:$requester,
   approvalIdentity:$approver}' >"$artifact_dir/.approval-evidence.json.tmp"
approval_sha=$(course_raw_sha256_file "$artifact_dir/.approval-evidence.json.tmp")
jq --arg approver "$approval_identity" --arg run "$run_id" \
  --arg approval "$approval_sha" '
  .approvalIdentity=$approver | .approvalRunId=$run |
  .approvalEvidenceSha256=("sha256:"+$approval)
' "$manifest" >"$artifact_dir/.plan-identity.json.tmp"
mv -- "$artifact_dir/.approval-evidence.json.tmp" "$artifact_dir/approval-evidence.json"
mv -- "$artifact_dir/.plan-identity.json.tmp" "$manifest"
