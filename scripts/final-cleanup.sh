#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
source "$SCRIPT_DIR/lib/evidence-common.sh"
source "$SCRIPT_DIR/lib/cleanup-evidence.sh"

pb_prepare_commands

saved_plan_manifest=''
apply_progress=''
inventory=''
decisions=''
preflight=''
in_flight=''
freeze=''
removal=''
dev_context=''
prod_context=''
pre_destroy_output=''
residual_output=''
execute=false
confirm_account=''
confirm_region=''
confirm_owner=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --saved-plan-manifest) saved_plan_manifest=${2:-}; shift 2 ;;
    --apply-progress) apply_progress=${2:-}; shift 2 ;;
    --inventory) inventory=${2:-}; shift 2 ;;
    --retain-decisions) decisions=${2:-}; shift 2 ;;
    --preflight-evidence) preflight=${2:-}; shift 2 ;;
    --in-flight-evidence) in_flight=${2:-}; shift 2 ;;
    --gitops-freeze-evidence) freeze=${2:-}; shift 2 ;;
    --gitops-removal-evidence) removal=${2:-}; shift 2 ;;
    --dev-context) dev_context=${2:-}; shift 2 ;;
    --prod-context) prod_context=${2:-}; shift 2 ;;
    --kubernetes-pre-destroy-output) pre_destroy_output=${2:-}; shift 2 ;;
    --residual-output) residual_output=${2:-}; shift 2 ;;
    --execute) execute=true; shift ;;
    --confirm-account-id) confirm_account=${2:-}; shift 2 ;;
    --confirm-region) confirm_region=${2:-}; shift 2 ;;
    --confirm-owner-id) confirm_owner=${2:-}; shift 2 ;;
    *) pb_fail "unknown argument: $1" 64 ;;
  esac
done
for name in saved_plan_manifest apply_progress inventory decisions preflight in_flight freeze removal dev_context prod_context pre_destroy_output residual_output; do
  [[ -n "${!name}" ]] || pb_fail "--${name//_/-} is required" 64
done

cleanup_validate_saved_plan_manifest "$saved_plan_manifest" "$REPO_ROOT" "$inventory"
cleanup_require_canonical_runtime_output "$apply_progress" "$REPO_ROOT" saved-plan-progress.json
cleanup_validate_decisions "$inventory" "$decisions"
cleanup_validate_freeze_removal "$inventory" "$freeze" "$removal"
pb_require_file "$preflight"
cleanup_assert_canonical_utc_seconds "$preflight" 'cleanup preflight timestamps' \
  '["observedAt"]' '["expiresAt"]'
pb_require_file "$in_flight"

pb_assert_json "$preflight" '
  def nonblank: type == "string" and test("[^[:space:]\uFEFF]");
  keys == ["accountId","evidenceGrade","expiresAt","inventorySha256","observedAt","ownerId","planSha256","project","region","schemaVersion","status"] and
  .schemaVersion == "playbuilder.cleanup-preflight/v1" and .evidenceGrade == "CLOUD_RUNTIME" and .status == "PASS" and
  (.project | type == "string" and test("[^[:space:]\uFEFF]")) and
  (.ownerId | nonblank) and (.accountId | test("^[0-9]{12}$")) and
  (.region == "ap-northeast-2" or .region == "us-east-1") and
  (.planSha256 | test("^[0-9a-f]{64}$")) and (.inventorySha256 | test("^[0-9a-f]{64}$")) and
  (.observedAt | fromdateiso8601) <= now and now < (.expiresAt | fromdateiso8601)
' 'invalid, static, or expired cleanup preflight evidence'
pb_assert_json "$in_flight" '
  def nonblank: type == "string" and test("[^[:space:]\uFEFF]");
  def utc_seconds:
    type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
    (. == (fromdateiso8601 | todateiso8601));
  . as $evidence |
  ($evidence | keys) == ["accountId","clusters","evidenceGrade","expiresAt","observedAt","ownerId","region","remainingWriters","schemaVersion","status"] and
  $evidence.schemaVersion == "playbuilder.in-flight-zero/v1" and $evidence.evidenceGrade == "CLOUD_RUNTIME" and $evidence.status == "PASS" and
  ($evidence.ownerId | nonblank) and ($evidence.accountId | test("^[0-9]{12}$")) and
  ($evidence.region == "ap-northeast-2" or $evidence.region == "us-east-1") and
  [$evidence.clusters[].environment] == ["dev","prod"] and
  all($evidence.clusters[];
    keys == ["clusterArn","context","environment"] and
    (.context | nonblank) and
    (.clusterArn | test("^arn:aws:eks:" + $evidence.region + ":" + $evidence.accountId + ":cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$"))) and
  $evidence.clusters[0].context != $evidence.clusters[1].context and
  $evidence.clusters[0].clusterArn != $evidence.clusters[1].clusterArn and
  ($evidence.remainingWriters | keys == ["chaosResources","loadGenerators","migrationJobs","recoveryJobs"]) and
  ([$evidence.remainingWriters[]] | all(type == "number" and floor == . and . == 0)) and
  ($evidence.observedAt | utc_seconds) and ($evidence.expiresAt | utc_seconds) and
  ($evidence.observedAt | fromdateiso8601) <= now and now < ($evidence.expiresAt | fromdateiso8601)
' 'invalid, static, expired, or nonzero in-flight evidence'

inventory_owner=$(jq -r '.ownerId' "$inventory")
inventory_account=$(jq -r '.accountId' "$inventory")
inventory_region=$(jq -r '.region' "$inventory")
[[ $(jq -r '.planSha256' "$preflight") == "$(pb_raw_sha256_file "$saved_plan_manifest")" ]] || pb_fail 'CLEANUP_PLAN_DIGEST_MISMATCH'
[[ $(jq -r '.inventorySha256' "$preflight") == "$(pb_raw_sha256_file "$inventory")" ]] || pb_fail 'CLEANUP_INVENTORY_DIGEST_MISMATCH'
jq -en --arg owner "$inventory_owner" --arg account "$inventory_account" --arg region "$inventory_region" \
  --arg devContext "$dev_context" --arg prodContext "$prod_context" \
  --argjson preflight "$(jq -c . "$preflight")" --argjson inFlight "$(jq -c . "$in_flight")" \
  --argjson freeze "$(jq -c . "$freeze")" --argjson removal "$(jq -c . "$removal")" '
  $preflight.ownerId == $owner and $preflight.accountId == $account and $preflight.region == $region and
  $inFlight.ownerId == $owner and $inFlight.accountId == $account and $inFlight.region == $region and
  $inFlight.clusters == [
    {environment:"dev",context:$devContext,clusterArn:$freeze.clusters[0].clusterArn},
    {environment:"prod",context:$prodContext,clusterArn:$freeze.clusters[1].clusterArn}
  ] and
  [$freeze.clusters[] | {environment,clusterArn}] == $removal.clusters
' >/dev/null || pb_fail 'CLEANUP_GUARD_IDENTITY_MISMATCH'

max_age=${CLEANUP_RUNTIME_EVIDENCE_MAX_AGE_SECONDS:-86400}
[[ "$max_age" =~ ^[1-9][0-9]*$ ]] || pb_fail 'CLEANUP_RUNTIME_EVIDENCE_MAX_AGE_SECONDS must be positive' 64
jq -en --argjson freeze "$(jq -c . "$freeze")" --argjson removal "$(jq -c . "$removal")" --argjson maxAge "$max_age" '
  (now - ($freeze.observedAt | fromdateiso8601)) <= $maxAge and
  (now - ($removal.observedAt | fromdateiso8601)) <= $maxAge
' >/dev/null || pb_fail 'STALE_GITOPS_CLEANUP_EVIDENCE'

print_dry_run() {
  echo 'DRY-RUN phase 1/6: verify account scope and ownership classification.'
  echo 'DRY-RUN phase 2/6: verify zero writers, retention decisions, snapshots, state, and external delete guards.'
  echo 'DRY-RUN phase 3/6: consume the GitOps reconciliation freeze evidence.'
  echo 'DRY-RUN phase 4/6: consume the reviewed desired-state removal evidence.'
  echo 'DRY-RUN phase 5/6: scan Kubernetes before EKS deletion, then apply reviewed saved plans.'
  echo 'DRY-RUN phase 6/6: scan AWS residuals without kubectl and write completion evidence.'
  [[ "${PLATFORM_CHECK_DETAIL_ONLY:-false}" == true ]] || echo 'PASS: [STATIC] final cleanup plan validated without mutation.'
}

if [[ "$execute" != true ]]; then
  print_dry_run
  exit 0
fi

[[ -n "$confirm_account" && -n "$confirm_region" && -n "$confirm_owner" ]] || pb_fail 'FINAL_CLEANUP_CONFIRMATIONS_REQUIRED' 64
[[ "$confirm_account" == "$inventory_account" ]] || pb_fail 'FINAL_CLEANUP_ACCOUNT_CONFIRMATION_MISMATCH'
[[ "$confirm_region" == "$inventory_region" ]] || pb_fail 'FINAL_CLEANUP_REGION_CONFIRMATION_MISMATCH'
[[ "$confirm_owner" == "$inventory_owner" ]] || pb_fail 'FINAL_CLEANUP_PLATFORM_CONFIRMATION_MISMATCH'
: "${AWS_PROFILE:?AWS_PROFILE is required for execute}"
: "${AWS_REGION:?AWS_REGION is required for execute}"
: "${OWNER_ID:?OWNER_ID is required for execute}"
[[ "$AWS_REGION" == "$confirm_region" ]] || pb_fail 'FINAL_CLEANUP_SELECTED_REGION_MISMATCH'
[[ "$OWNER_ID" == "$confirm_owner" ]] || pb_fail 'FINAL_CLEANUP_SELECTED_PLATFORM_MISMATCH'
pb_validate_region "$confirm_region"
pb_validate_account "$confirm_account"
[[ $(jq -r '.evidenceGrade' "$inventory") == CLOUD_RUNTIME ]] || pb_fail 'STATIC_INVENTORY_EXECUTION_BLOCKED'
cleanup_require_canonical_runtime_output "$pre_destroy_output" "$REPO_ROOT" kubernetes-pre-destroy.json
cleanup_require_canonical_runtime_output "$residual_output" "$REPO_ROOT" residual.json
for command_name in aws kubectl terraform jq; do command -v "$command_name" >/dev/null || pb_fail "required command not found: $command_name" 69; done

caller=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --region "$confirm_region" --output json)
[[ $(jq -r '.Account' <<<"$caller") == "$confirm_account" ]] || pb_fail 'FINAL_CLEANUP_CALLER_ACCOUNT_MISMATCH'

export AWS_ACCOUNT_ID="$confirm_account"
export AWS_REGION="$confirm_region"
export OWNER_ID="$confirm_owner"

stage() {
  local number=$1
  if [[ -n "${PLATFORM_CLEANUP_STAGE_LOG:-}" ]]; then echo "$number" >>"$PLATFORM_CLEANUP_STAGE_LOG"; fi
}

stage 1
python3 "$SCRIPT_DIR/lib/enterprise-cleanup.py" discover "$inventory" || pb_fail ENTERPRISE_DISCOVERY_INCOMPLETE
echo 'PHASE 1/6 scope: account identity verified.'
stage 2
stage 3
echo 'PHASE 2/6 retention decision: zero writers and protected handles verified.'
stage 4
stage 5
stage 6
stage 7
echo 'PHASE 3/6 reconcile freeze: GitOps writers are frozen.'
stage 8
echo 'PHASE 4/6 desired-state removal: reviewed GitOps removal is accepted.'
stage 9
stage 10
echo 'PHASE 5/6 resource cleanup: collecting the final Kubernetes observation before EKS deletion.'
if ! bash "$SCRIPT_DIR/kubernetes-pre-destroy-scan.sh" \
  --inventory "$inventory" --gitops-removal "$removal" \
  --dev-context "$dev_context" --prod-context "$prod_context" --output "$pre_destroy_output"; then
  pb_fail 'KUBERNETES_PRE_DESTROY_SCAN_FAILED'
fi
stage 11
stage 12
stage 13
cleanup_apply_saved_plans "$saved_plan_manifest" "$REPO_ROOT" "$inventory" "$apply_progress" "$(jq -r '.project' "$preflight")"
stage 14
echo 'PHASE 6/6 completion proof: scanning AWS residuals without Kubernetes API calls.'
if ! bash "$SCRIPT_DIR/residual-scan.sh" \
  --inventory "$inventory" --retain-decisions "$decisions" \
  --kubernetes-pre-destroy "$pre_destroy_output" --gitops-removal "$removal" --output "$residual_output"; then
  pb_fail 'AWS_RESIDUAL_SCAN_FAILED'
fi
stage 15
cleanup_validate_residual "$inventory" "$decisions" "$pre_destroy_output" "$removal" "$residual_output"
if [[ "${PLATFORM_CHECK_DETAIL_ONLY:-false}" != true ]]; then
  if [[ -n "${PLATFORM_CHECK_BIN_DIR:-}" ]]; then
    echo 'PASS: [STATIC] SIMULATED_CLOUD_CONTRACT guarded final cleanup workflow passed.'
  else
    echo 'PASS: [CLOUD_RUNTIME] final cleanup completed with zero unapproved billable residuals.'
  fi
fi
