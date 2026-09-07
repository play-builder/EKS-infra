#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
source "$SCRIPT_DIR/lib/evidence-common.sh"
source "$SCRIPT_DIR/lib/cleanup-evidence.sh"

pb_prepare_commands
approval=''
saved_plan_manifest=''
apply_progress=''
inventory=''
decisions=''
output=''
execute=false
confirm_account=''
confirm_region=''
confirm_owner=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --approval) approval=${2:-}; shift 2 ;;
    --saved-plan-manifest) saved_plan_manifest=${2:-}; shift 2 ;;
    --apply-progress) apply_progress=${2:-}; shift 2 ;;
    --inventory) inventory=${2:-}; shift 2 ;;
    --retain-decisions) decisions=${2:-}; shift 2 ;;
    --output) output=${2:-}; shift 2 ;;
    --execute) execute=true; shift ;;
    --confirm-account-id) confirm_account=${2:-}; shift 2 ;;
    --confirm-region) confirm_region=${2:-}; shift 2 ;;
    --confirm-owner-id) confirm_owner=${2:-}; shift 2 ;;
    *) pb_fail "unknown argument: $1" 64 ;;
  esac
done
for name in approval saved_plan_manifest apply_progress inventory decisions output; do [[ -n "${!name}" ]] || pb_fail "--${name//_/-} is required" 64; done
pb_require_file "$approval"
pb_assert_canonical_utc_seconds "$approval" 'checkpoint approval timestamps' \
  '["approvedAt"]' '["expiresAt"]'
cleanup_validate_decisions "$inventory" "$decisions"
cleanup_validate_saved_plan_manifest "$saved_plan_manifest" "$REPO_ROOT"
cleanup_require_canonical_runtime_output "$apply_progress" "$REPO_ROOT" saved-plan-progress.json

pb_assert_json "$approval" '
  keys == ["accountId","approvedAt","evidenceGrade","expiresAt","flags","layers","ownerId","project","region","retainedKinds","schemaVersion","stateKeys","status","versions"] and
  .schemaVersion == "playbuilder.checkpoint-approval/v1" and .evidenceGrade == "LOCAL_RUNTIME" and .status == "APPROVED" and
  (.project | type == "string" and test("[^[:space:]\uFEFF]")) and
  (.accountId | test("^[0-9]{12}$")) and (.region == "ap-northeast-2" or .region == "us-east-1") and
  .layers == [
    "environments/prod/04-workloads/argocd","environments/dev/04-workloads/argocd",
    "environments/prod/03-platform","environments/dev/03-platform",
    "environments/prod/02-eks","environments/dev/02-eks",
    "environments/prod/01-network","environments/dev/01-network"] and
  .retainedKinds == ["EbsSnapshot","EcrRepository","SecretsManagerSecret","TerraformState","PlatformEvidence"] and
  (.stateKeys | type == "array" and length == 8 and ((unique | length) == 8)) and
  (.versions | type == "object" and length > 0) and (.flags | type == "object" and length > 0) and
  (.approvedAt | fromdateiso8601) <= now and now < (.expiresAt | fromdateiso8601)
' 'invalid or expired checkpoint approval'

jq -en --argjson approval "$(jq -c . "$approval")" --argjson inventory "$(jq -c . "$inventory")" '
  $approval.ownerId == $inventory.ownerId and $approval.accountId == $inventory.accountId and $approval.region == $inventory.region
' >/dev/null || pb_fail 'CHECKPOINT_IDENTITY_MISMATCH'

if [[ "$execute" != true ]]; then
  echo 'DRY-RUN: checkpoint teardown would apply eight reviewed saved plans and retain state, evidence, Secret, snapshot, and ECR handles.'
  [[ "${PLATFORM_CHECK_DETAIL_ONLY:-false}" == true ]] || echo 'PASS: [STATIC] checkpoint teardown plan validated without mutation.'
  exit 0
fi

[[ -n "$confirm_account" && -n "$confirm_region" && -n "$confirm_owner" ]] || pb_fail 'CHECKPOINT_CONFIRMATIONS_REQUIRED' 64
[[ "$confirm_account" == "$(jq -r '.accountId' "$approval")" ]] || pb_fail 'CHECKPOINT_ACCOUNT_CONFIRMATION_MISMATCH'
[[ "$confirm_region" == "$(jq -r '.region' "$approval")" ]] || pb_fail 'CHECKPOINT_REGION_CONFIRMATION_MISMATCH'
[[ "$confirm_owner" == "$(jq -r '.ownerId' "$approval")" ]] || pb_fail 'CHECKPOINT_PLATFORM_CONFIRMATION_MISMATCH'
pb_validate_region "$confirm_region"
pb_validate_account "$confirm_account"
: "${AWS_PROFILE:?AWS_PROFILE is required for execute}"
caller=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --region "$confirm_region" --output json)
[[ $(jq -r '.Account' <<<"$caller") == "$confirm_account" ]] || pb_fail 'CHECKPOINT_CALLER_ACCOUNT_MISMATCH'

[[ $(jq -c '.layers' "$approval") == "$(cleanup_expected_destroy_layers_json)" ]] || \
  pb_fail 'CHECKPOINT_SAVED_PLAN_LAYER_MISMATCH'
cleanup_apply_saved_plans "$saved_plan_manifest" "$REPO_ROOT" "$inventory" "$apply_progress" "$(jq -r '.project' "$approval")"

observed=$(pb_now)
payload=$(jq -n --argjson approval "$(jq -c . "$approval")" --argjson inventory "$(jq -c . "$inventory")" \
  --arg observed "$observed" '
  {
    schemaVersion:"playbuilder.checkpoint-resume/v1", evidenceGrade:"LOCAL_RUNTIME", status:"PARTIAL_TEARDOWN",
    ownerId:$approval.ownerId, accountId:$approval.accountId, region:$approval.region,
    stateKeys:$approval.stateKeys,
    retained:([$inventory.resources[] | select(.decision != "DELETE") |
      {kind,id,owner,reason,followUpAction}] | sort_by(.kind,.id)),
    versions:$approval.versions, flags:$approval.flags,
    dependencyOrder:["state-backend","shared-identity","network","eks","platform","controllers","applications"],
    observedAt:$observed
  }
')
pb_write_json "$output" "$payload"
[[ "${PLATFORM_CHECK_DETAIL_ONLY:-false}" == true ]] || echo 'PASS: [LOCAL_RUNTIME] checkpoint partial teardown completed; full cleanup completion requires final-cleanup.sh.'
