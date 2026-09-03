#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
source "$SCRIPT_DIR/lib/evidence-common.sh"
source "$SCRIPT_DIR/lib/cleanup-evidence.sh"

if [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then
  [[ -d "$COURSE_CHECK_BIN_DIR" ]] || course_fail 'COURSE_CHECK_BIN_DIR is not a directory' 64
  PATH="$COURSE_CHECK_BIN_DIR:$PATH"
fi

plan=''
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
confirm_course=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan) plan=${2:-}; shift 2 ;;
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
    --confirm-course-id) confirm_course=${2:-}; shift 2 ;;
    *) course_fail "unknown argument: $1" 64 ;;
  esac
done
for name in plan inventory decisions preflight in_flight freeze removal dev_context prod_context pre_destroy_output residual_output; do
  [[ -n "${!name}" ]] || course_fail "--${name//_/-} is required" 64
done

course_require_file "$plan"
cleanup_validate_decisions "$inventory" "$decisions"
cleanup_validate_freeze_removal "$inventory" "$freeze" "$removal"
course_require_file "$preflight"
course_require_file "$in_flight"

course_assert_json "$preflight" '
  def nonblank: type == "string" and test("\\S");
  keys == ["accountId","courseId","evidenceGrade","expiresAt","inventorySha256","observedAt","planSha256","region","schemaVersion","status"] and
  .schemaVersion == "course.cleanup-preflight/v1" and .evidenceGrade == "CLOUD_RUNTIME" and .status == "PASS" and
  (.courseId | nonblank) and (.accountId | test("^[0-9]{12}$")) and
  (.region == "ap-northeast-2" or .region == "us-east-1") and
  (.planSha256 | test("^[0-9a-f]{64}$")) and (.inventorySha256 | test("^[0-9a-f]{64}$")) and
  (.observedAt | fromdateiso8601) <= now and now < (.expiresAt | fromdateiso8601)
' 'invalid, static, or expired cleanup preflight evidence'
course_assert_json "$in_flight" '
  def nonblank: type == "string" and test("\\S");
  keys == ["accountId","courseId","evidenceGrade","expiresAt","observedAt","region","remainingWriters","schemaVersion","status"] and
  .schemaVersion == "course.in-flight-zero/v1" and .evidenceGrade == "CLOUD_RUNTIME" and .status == "PASS" and
  (.courseId | nonblank) and (.accountId | test("^[0-9]{12}$")) and
  (.region == "ap-northeast-2" or .region == "us-east-1") and
  (.remainingWriters | keys == ["chaosResources","loadGenerators","migrationJobs","recoveryJobs"]) and
  ([.remainingWriters[]] | all(type == "number" and floor == . and . == 0)) and
  (.observedAt | fromdateiso8601) <= now and now < (.expiresAt | fromdateiso8601)
' 'invalid, static, expired, or nonzero in-flight evidence'

inventory_course=$(jq -r '.courseId' "$inventory")
inventory_account=$(jq -r '.accountId' "$inventory")
inventory_region=$(jq -r '.region' "$inventory")
[[ $(jq -r '.planSha256' "$preflight") == "$(course_raw_sha256_file "$plan")" ]] || course_fail 'CLEANUP_PLAN_DIGEST_MISMATCH'
[[ $(jq -r '.inventorySha256' "$preflight") == "$(course_raw_sha256_file "$inventory")" ]] || course_fail 'CLEANUP_INVENTORY_DIGEST_MISMATCH'
jq -en --arg course "$inventory_course" --arg account "$inventory_account" --arg region "$inventory_region" \
  --argjson preflight "$(jq -c . "$preflight")" --argjson inFlight "$(jq -c . "$in_flight")" '
  $preflight.courseId == $course and $preflight.accountId == $account and $preflight.region == $region and
  $inFlight.courseId == $course and $inFlight.accountId == $account and $inFlight.region == $region
' >/dev/null || course_fail 'CLEANUP_GUARD_IDENTITY_MISMATCH'

max_age=${CLEANUP_RUNTIME_EVIDENCE_MAX_AGE_SECONDS:-86400}
[[ "$max_age" =~ ^[1-9][0-9]*$ ]] || course_fail 'CLEANUP_RUNTIME_EVIDENCE_MAX_AGE_SECONDS must be positive' 64
jq -en --argjson freeze "$(jq -c . "$freeze")" --argjson removal "$(jq -c . "$removal")" --argjson maxAge "$max_age" '
  (now - ($freeze.observedAt | fromdateiso8601)) <= $maxAge and
  (now - ($removal.observedAt | fromdateiso8601)) <= $maxAge
' >/dev/null || course_fail 'STALE_GITOPS_CLEANUP_EVIDENCE'

print_dry_run() {
  echo 'DRY-RUN phase 1/6: verify account scope and ownership classification.'
  echo 'DRY-RUN phase 2/6: verify zero writers, retention decisions, snapshots, state, and external delete guards.'
  echo 'DRY-RUN phase 3/6: consume the GitOps reconciliation freeze evidence.'
  echo 'DRY-RUN phase 4/6: consume the reviewed desired-state removal evidence.'
  echo 'DRY-RUN phase 5/6: scan Kubernetes before EKS deletion, then destroy allowlisted runtime layers.'
  echo 'DRY-RUN phase 6/6: scan AWS residuals without kubectl and write completion evidence.'
  [[ "${COURSE_CHECK_DETAIL_ONLY:-false}" == true ]] || echo 'PASS: [STATIC] final cleanup plan validated without mutation.'
}

if [[ "$execute" != true ]]; then
  print_dry_run
  exit 0
fi

[[ -n "$confirm_account" && -n "$confirm_region" && -n "$confirm_course" ]] || course_fail 'FINAL_CLEANUP_CONFIRMATIONS_REQUIRED' 64
[[ "$confirm_account" == "$inventory_account" ]] || course_fail 'FINAL_CLEANUP_ACCOUNT_CONFIRMATION_MISMATCH'
[[ "$confirm_region" == "$inventory_region" ]] || course_fail 'FINAL_CLEANUP_REGION_CONFIRMATION_MISMATCH'
[[ "$confirm_course" == "$inventory_course" ]] || course_fail 'FINAL_CLEANUP_COURSE_CONFIRMATION_MISMATCH'
: "${AWS_PROFILE:?AWS_PROFILE is required for execute}"
: "${AWS_REGION:?AWS_REGION is required for execute}"
: "${COURSE_ID:?COURSE_ID is required for execute}"
[[ "$AWS_REGION" == "$confirm_region" ]] || course_fail 'FINAL_CLEANUP_SELECTED_REGION_MISMATCH'
[[ "$COURSE_ID" == "$confirm_course" ]] || course_fail 'FINAL_CLEANUP_SELECTED_COURSE_MISMATCH'
course_validate_region "$confirm_region"
course_validate_account "$confirm_account"
[[ $(jq -r '.evidenceGrade' "$inventory") == CLOUD_RUNTIME ]] || course_fail 'STATIC_INVENTORY_EXECUTION_BLOCKED'
cleanup_require_canonical_runtime_output "$pre_destroy_output" "$REPO_ROOT" kubernetes-pre-destroy.json
cleanup_require_canonical_runtime_output "$residual_output" "$REPO_ROOT" residual.json
for command_name in aws kubectl terraform jq; do command -v "$command_name" >/dev/null || course_fail "required command not found: $command_name" 69; done

layers=(
  environments/prod/04-workloads/argocd
  environments/dev/04-workloads/argocd
  environments/prod/03-platform
  environments/dev/03-platform
  environments/prod/02-eks
  environments/dev/02-eks
  environments/prod/01-network
  environments/dev/01-network
)
for layer in "${layers[@]}"; do [[ -d "$REPO_ROOT/$layer" ]] || course_fail "cleanup layer not found: $layer"; done
caller=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --region "$confirm_region" --output json)
[[ $(jq -r '.Account' <<<"$caller") == "$confirm_account" ]] || course_fail 'FINAL_CLEANUP_CALLER_ACCOUNT_MISMATCH'

export AWS_ACCOUNT_ID="$confirm_account"
export AWS_REGION="$confirm_region"
export COURSE_ID="$confirm_course"

stage() {
  local number=$1
  if [[ -n "${COURSE_CLEANUP_STAGE_LOG:-}" ]]; then echo "$number" >>"$COURSE_CLEANUP_STAGE_LOG"; fi
}

stage 1
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
  course_fail 'KUBERNETES_PRE_DESTROY_SCAN_FAILED'
fi
stage 11
stage 12
stage 13
for layer in "${layers[@]}"; do
  terraform -chdir="$REPO_ROOT/$layer" destroy -auto-approve || course_fail "TERRAFORM_DESTROY_FAILED: $layer"
done
stage 14
echo 'PHASE 6/6 completion proof: scanning AWS residuals without Kubernetes API calls.'
if ! bash "$SCRIPT_DIR/residual-scan.sh" \
  --inventory "$inventory" --retain-decisions "$decisions" \
  --kubernetes-pre-destroy "$pre_destroy_output" --gitops-removal "$removal" --output "$residual_output"; then
  course_fail 'AWS_RESIDUAL_SCAN_FAILED'
fi
stage 15
cleanup_validate_residual "$inventory" "$decisions" "$pre_destroy_output" "$removal" "$residual_output"
if [[ "${COURSE_CHECK_DETAIL_ONLY:-false}" != true ]]; then
  if [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then
    echo 'PASS: [STATIC] SIMULATED_CLOUD_CONTRACT guarded final cleanup workflow passed.'
  else
    echo 'PASS: [CLOUD_RUNTIME] final cleanup completed with zero unapproved billable residuals.'
  fi
fi
