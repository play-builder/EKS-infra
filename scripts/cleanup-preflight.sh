#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
source "$SCRIPT_DIR/lib/evidence-common.sh"
source "$SCRIPT_DIR/lib/cleanup-evidence.sh"

plan=''
inventory_source=''
inventory_output=''
retain_template=''
preflight_output=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --plan) plan=${2:-}; shift 2 ;;
    --inventory-source) inventory_source=${2:-}; shift 2 ;;
    --inventory-output) inventory_output=${2:-}; shift 2 ;;
    --retain-template) retain_template=${2:-}; shift 2 ;;
    --preflight-output) preflight_output=${2:-}; shift 2 ;;
    *) course_fail "unknown argument: $1" 64 ;;
  esac
done
for name in plan inventory_source inventory_output retain_template preflight_output; do
  [[ -n "${!name}" ]] || course_fail "--${name//_/-} is required" 64
done
for name in COURSE_ID AWS_ACCOUNT_ID AWS_REGION COURSE_PROJECT; do [[ -n "${!name:-}" ]] || course_fail "$name is required" 64; done
course_validate_region "$AWS_REGION"
course_validate_account "$AWS_ACCOUNT_ID"
cleanup_require_canonical_runtime_output "$inventory_output" "$REPO_ROOT" ownership-inventory.json
cleanup_require_canonical_runtime_output "$retain_template" "$REPO_ROOT" retain-decisions.json
cleanup_reject_runtime_output_from_fixture "$preflight_output" "$REPO_ROOT" preflight.json
course_require_file "$plan"
cleanup_validate_inventory "$inventory_source"

jq -e '.format_version | type == "string"' "$plan" >/dev/null || course_fail 'invalid Terraform JSON plan'
jq -e '.resource_changes | type == "array"' "$plan" >/dev/null || course_fail 'Terraform plan has no resource_changes array'

while IFS= read -r change; do
  id=$(jq -r '.change.before.id // empty' <<<"$change")
  type=$(jq -r '.type' <<<"$change")
  [[ -n "$id" ]] || course_fail 'UNCLASSIFIED_DELETE_HANDLE'
  if [[ "$type" == aws_iam_openid_connect_provider ]] && \
    ! jq -e '.change.before.oidc_provider_owned_by_course == true' <<<"$change" >/dev/null; then
    course_fail "EXTERNAL_RESOURCE_DELETE_BLOCKED: $id"
  fi
  decision=$(jq -r --arg id "$id" '[.resources[] | select(.id == $id)] | if length == 1 then .[0].decision else empty end' "$inventory_source")
  case "$decision" in
    DELETE) ;;
    EXTERNAL_SHARED) course_fail "EXTERNAL_RESOURCE_DELETE_BLOCKED: $id" ;;
    RETAIN) course_fail "RETAINED_RESOURCE_DELETE_BLOCKED: $id" ;;
    *) course_fail "UNCLASSIFIED_DELETE_HANDLE: $id" ;;
  esac
  jq -e --arg course "$COURSE_ID" --arg account "$AWS_ACCOUNT_ID" --arg region "$AWS_REGION" --arg project "$COURSE_PROJECT" '
    .change.before.tags.CourseId == $course and .change.before.tags.AccountId == $account and
    .change.before.tags.Region == $region and .change.before.tags.Project == $project and
    (.change.before.tags.Environment == "dev" or .change.before.tags.Environment == "prod" or .change.before.tags.Environment == "shared") and
    (.change.before.tags.Layer | type == "string" and length > 0) and .change.before.tags.ManagedBy == "terraform"
  ' <<<"$change" >/dev/null || course_fail "OWNERSHIP_TAG_MISMATCH: $id"
done < <(jq -c '.resource_changes[] | select(.change.actions | index("delete"))' "$plan")

grade=CLOUD_RUNTIME
[[ -z "${COURSE_CHECK_BIN_DIR:-}" ]] || grade=STATIC
observed=$(course_now)
expires=$(course_expires_after "${CLEANUP_PREFLIGHT_TTL_SECONDS:-3600}")
inventory_payload=$(jq --arg grade "$grade" --arg observed "$observed" '
  .evidenceGrade=$grade | .observedAt=$observed | .resources |= sort_by(.kind,.id)
' "$inventory_source")

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
printf '%s\n' "$inventory_payload" >"$tmp_dir/inventory.json"
inventory_sha=$(course_raw_sha256_file "$tmp_dir/inventory.json")
plan_sha=$(course_raw_sha256_file "$plan")
retain_payload=$(jq -n --arg course "$COURSE_ID" --arg account "$AWS_ACCOUNT_ID" --arg region "$AWS_REGION" \
  --arg inventory "$inventory_sha" --arg observed "$observed" --argjson source "$inventory_payload" '
  {
    schemaVersion:"course.cleanup-retain-decisions/v1", evidenceGrade:"LOCAL_RUNTIME", status:"PENDING",
    courseId:$course, accountId:$account, region:$region, inventorySha256:$inventory,
    decisions:([$source.resources[] | select(.decision != "DELETE") |
      {kind,id,decision,reason,followUpAction}] | sort_by(.kind,.id)),
    approvedAt:null
  }
')
preflight_payload=$(jq -n --arg grade "$grade" --arg course "$COURSE_ID" --arg account "$AWS_ACCOUNT_ID" \
  --arg region "$AWS_REGION" --arg plan "$plan_sha" --arg inventory "$inventory_sha" \
  --arg observed "$observed" --arg expires "$expires" '
  {schemaVersion:"course.cleanup-preflight/v1",evidenceGrade:$grade,status:"PASS",courseId:$course,
   accountId:$account,region:$region,planSha256:$plan,inventorySha256:$inventory,observedAt:$observed,expiresAt:$expires}
')

course_write_json "$inventory_output" "$inventory_payload"
course_write_json "$retain_template" "$retain_payload"
course_write_json "$preflight_output" "$preflight_payload"
if [[ "${COURSE_CHECK_DETAIL_ONLY:-false}" != true ]]; then
  if [[ "$grade" == STATIC ]]; then
    echo 'PASS: [STATIC] SIMULATED_CLOUD_CONTRACT cleanup ownership preflight passed.'
  else
    echo 'PASS: [CLOUD_RUNTIME] cleanup ownership preflight passed.'
  fi
fi
