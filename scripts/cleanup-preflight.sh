#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd -P)
source "$SCRIPT_DIR/lib/evidence-common.sh"
source "$SCRIPT_DIR/lib/cleanup-evidence.sh"

saved_plan_manifest=''
inventory_source=''
inventory_output=''
retain_template=''
preflight_output=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --saved-plan-manifest) saved_plan_manifest=${2:-}; shift 2 ;;
    --inventory-source) inventory_source=${2:-}; shift 2 ;;
    --inventory-output) inventory_output=${2:-}; shift 2 ;;
    --retain-template) retain_template=${2:-}; shift 2 ;;
    --preflight-output) preflight_output=${2:-}; shift 2 ;;
    *) pb_fail "unknown argument: $1" 64 ;;
  esac
done
for name in saved_plan_manifest inventory_source inventory_output retain_template preflight_output; do
  [[ -n "${!name}" ]] || pb_fail "--${name//_/-} is required" 64
done
for name in OWNER_ID AWS_ACCOUNT_ID AWS_REGION PROJECT_NAME; do [[ -n "${!name:-}" ]] || pb_fail "$name is required" 64; done
pb_validate_region "$AWS_REGION"
pb_validate_account "$AWS_ACCOUNT_ID"
cleanup_require_canonical_runtime_output "$inventory_output" "$REPO_ROOT" ownership-inventory.json
cleanup_require_canonical_runtime_output "$retain_template" "$REPO_ROOT" retain-decisions.json
cleanup_reject_runtime_output_from_fixture "$preflight_output" "$REPO_ROOT" preflight.json
cleanup_validate_saved_plan_manifest "$saved_plan_manifest" "$REPO_ROOT" "$inventory_source"
cleanup_validate_inventory "$inventory_source"

while IFS=$'\t' read -r layer saved_plan _expected_sha; do
  cleanup_validate_saved_plan_file "$saved_plan" "$_expected_sha" "$layer"
  cleanup_validate_saved_destroy_plan "$layer" "$saved_plan" "$inventory_source" "$REPO_ROOT" \
    "$OWNER_ID" "$AWS_ACCOUNT_ID" "$AWS_REGION" "$PROJECT_NAME"
done < <(jq -r '.plans[] | [.layer,.path,.sha256] | @tsv' "$saved_plan_manifest")
python3 "$SCRIPT_DIR/lib/enterprise-cleanup.py" guard-manifest "$saved_plan_manifest" "$inventory_source" "$REPO_ROOT" || pb_fail ENTERPRISE_CLEANUP_GUARD_FAILED

grade=CLOUD_RUNTIME
[[ -z "${PLATFORM_CHECK_BIN_DIR:-}" ]] || grade=STATIC
observed=$(pb_now)
expires=$(pb_expires_after "${CLEANUP_PREFLIGHT_TTL_SECONDS:-3600}")
inventory_payload=$(jq --arg grade "$grade" --arg observed "$observed" '
  .evidenceGrade=$grade | .observedAt=$observed | .resources |= sort_by(.kind,.id)
' "$inventory_source")

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
printf '%s\n' "$inventory_payload" >"$tmp_dir/inventory.json"
inventory_sha=$(pb_raw_sha256_file "$tmp_dir/inventory.json")
plan_sha=$(pb_raw_sha256_file "$saved_plan_manifest")
retain_payload=$(jq -n --arg owner "$OWNER_ID" --arg account "$AWS_ACCOUNT_ID" --arg region "$AWS_REGION" \
  --arg inventory "$inventory_sha" --arg observed "$observed" --argjson source "$inventory_payload" '
  {
    schemaVersion:"playbuilder.cleanup-retain-decisions/v1", evidenceGrade:"LOCAL_RUNTIME", status:"PENDING",
    ownerId:$owner, accountId:$account, region:$region, inventorySha256:$inventory,
    decisions:([$source.resources[] | select(.decision != "DELETE") |
      {kind,id,decision,reason,followUpAction}] | sort_by(.kind,.id)),
    approvedAt:null
  }
')
preflight_payload=$(jq -n --arg grade "$grade" --arg owner "$OWNER_ID" --arg account "$AWS_ACCOUNT_ID" \
  --arg region "$AWS_REGION" --arg project "$PROJECT_NAME" --arg plan "$plan_sha" --arg inventory "$inventory_sha" \
  --arg observed "$observed" --arg expires "$expires" '
  {schemaVersion:"playbuilder.cleanup-preflight/v1",evidenceGrade:$grade,status:"PASS",ownerId:$owner,
   accountId:$account,region:$region,project:$project,planSha256:$plan,inventorySha256:$inventory,observedAt:$observed,expiresAt:$expires}
')

pb_write_json "$inventory_output" "$inventory_payload"
pb_write_json "$retain_template" "$retain_payload"
pb_write_json "$preflight_output" "$preflight_payload"
if [[ "${PLATFORM_CHECK_DETAIL_ONLY:-false}" != true ]]; then
  if [[ "$grade" == STATIC ]]; then
    echo 'PASS: [STATIC] SIMULATED_CLOUD_CONTRACT cleanup ownership preflight passed.'
  else
    echo 'PASS: [CLOUD_RUNTIME] cleanup ownership preflight passed.'
  fi
fi
