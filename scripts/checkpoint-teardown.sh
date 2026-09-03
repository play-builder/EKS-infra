#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
source "$SCRIPT_DIR/lib/evidence-common.sh"
source "$SCRIPT_DIR/lib/cleanup-evidence.sh"

if [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then PATH="$COURSE_CHECK_BIN_DIR:$PATH"; fi
approval=''
inventory=''
decisions=''
output=''
execute=false
confirm_account=''
confirm_region=''
confirm_course=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --approval) approval=${2:-}; shift 2 ;;
    --inventory) inventory=${2:-}; shift 2 ;;
    --retain-decisions) decisions=${2:-}; shift 2 ;;
    --output) output=${2:-}; shift 2 ;;
    --execute) execute=true; shift ;;
    --confirm-account-id) confirm_account=${2:-}; shift 2 ;;
    --confirm-region) confirm_region=${2:-}; shift 2 ;;
    --confirm-course-id) confirm_course=${2:-}; shift 2 ;;
    *) course_fail "unknown argument: $1" 64 ;;
  esac
done
for name in approval inventory decisions output; do [[ -n "${!name}" ]] || course_fail "--${name//_/-} is required" 64; done
course_require_file "$approval"
course_assert_canonical_utc_seconds "$approval" 'checkpoint approval timestamps' \
  '["approvedAt"]' '["expiresAt"]'
cleanup_validate_decisions "$inventory" "$decisions"

course_assert_json "$approval" '
  keys == ["accountId","approvedAt","courseId","evidenceGrade","expiresAt","flags","layers","region","retainedKinds","schemaVersion","stateKeys","status","versions"] and
  .schemaVersion == "course.checkpoint-approval/v1" and .evidenceGrade == "LOCAL_RUNTIME" and .status == "APPROVED" and
  (.accountId | test("^[0-9]{12}$")) and (.region == "ap-northeast-2" or .region == "us-east-1") and
  .layers == [
    "environments/prod/04-workloads/argocd","environments/dev/04-workloads/argocd",
    "environments/prod/03-platform","environments/dev/03-platform",
    "environments/prod/02-eks","environments/dev/02-eks",
    "environments/prod/01-network","environments/dev/01-network"] and
  .retainedKinds == ["EbsSnapshot","EcrRepository","SecretsManagerSecret","TerraformState","CourseEvidence"] and
  (.stateKeys | type == "array" and length == 8 and ((unique | length) == 8)) and
  (.versions | type == "object" and length > 0) and (.flags | type == "object" and length > 0) and
  (.approvedAt | fromdateiso8601) <= now and now < (.expiresAt | fromdateiso8601)
' 'invalid or expired checkpoint approval'

jq -en --argjson approval "$(jq -c . "$approval")" --argjson inventory "$(jq -c . "$inventory")" '
  $approval.courseId == $inventory.courseId and $approval.accountId == $inventory.accountId and $approval.region == $inventory.region
' >/dev/null || course_fail 'CHECKPOINT_IDENTITY_MISMATCH'

if [[ "$execute" != true ]]; then
  echo 'DRY-RUN: checkpoint teardown would destroy eight allowlisted runtime layers and retain state, evidence, Secret, snapshot, and ECR handles.'
  [[ "${COURSE_CHECK_DETAIL_ONLY:-false}" == true ]] || echo 'PASS: [STATIC] checkpoint teardown plan validated without mutation.'
  exit 0
fi

[[ -n "$confirm_account" && -n "$confirm_region" && -n "$confirm_course" ]] || course_fail 'CHECKPOINT_CONFIRMATIONS_REQUIRED' 64
[[ "$confirm_account" == "$(jq -r '.accountId' "$approval")" ]] || course_fail 'CHECKPOINT_ACCOUNT_CONFIRMATION_MISMATCH'
[[ "$confirm_region" == "$(jq -r '.region' "$approval")" ]] || course_fail 'CHECKPOINT_REGION_CONFIRMATION_MISMATCH'
[[ "$confirm_course" == "$(jq -r '.courseId' "$approval")" ]] || course_fail 'CHECKPOINT_COURSE_CONFIRMATION_MISMATCH'
course_validate_region "$confirm_region"
course_validate_account "$confirm_account"
: "${AWS_PROFILE:?AWS_PROFILE is required for execute}"
caller=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --region "$confirm_region" --output json)
[[ $(jq -r '.Account' <<<"$caller") == "$confirm_account" ]] || course_fail 'CHECKPOINT_CALLER_ACCOUNT_MISMATCH'

while IFS= read -r layer; do
  [[ -d "$REPO_ROOT/$layer" ]] || course_fail "checkpoint layer not found: $layer"
done < <(jq -r '.layers[]' "$approval")

while IFS= read -r layer; do
  terraform -chdir="$REPO_ROOT/$layer" destroy -auto-approve
done < <(jq -r '.layers[]' "$approval")

observed=$(course_now)
payload=$(jq -n --argjson approval "$(jq -c . "$approval")" --argjson inventory "$(jq -c . "$inventory")" \
  --arg observed "$observed" '
  {
    schemaVersion:"course.checkpoint-resume/v1", evidenceGrade:"LOCAL_RUNTIME", status:"PARTIAL_TEARDOWN",
    courseId:$approval.courseId, accountId:$approval.accountId, region:$approval.region,
    stateKeys:$approval.stateKeys,
    retained:([$inventory.resources[] | select(.decision != "DELETE") |
      {kind,id,owner,reason,followUpAction}] | sort_by(.kind,.id)),
    versions:$approval.versions, flags:$approval.flags,
    dependencyOrder:["state-backend","shared-identity","network","eks","platform","controllers","applications"],
    observedAt:$observed
  }
')
course_write_json "$output" "$payload"
[[ "${COURSE_CHECK_DETAIL_ONLY:-false}" == true ]] || echo 'PASS: [LOCAL_RUNTIME] checkpoint partial teardown completed; this is not Ch26 completion evidence.'
