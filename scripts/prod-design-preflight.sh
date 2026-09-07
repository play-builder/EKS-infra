#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/evidence-common.sh"

[[ $# -eq 6 ]] || pb_fail 'usage: prod-design-preflight.sh <dev-deployment.json> <dev-slo.json> <dev-ready.json> <network-plan-summary.json> <capacity-input.json> <output.json>' 64
deployment=$1
slo=$2
ready=$3
network_plan=$4
capacity_input=$5
output=$6
for name in OWNER_ID AWS_ACCOUNT_ID AWS_REGION; do [[ -n "${!name:-}" ]] || pb_fail "$name is required" 64; done
pb_validate_region "$AWS_REGION"
pb_validate_account "$AWS_ACCOUNT_ID"
for file in "$network_plan" "$capacity_input"; do pb_require_file "$file"; done
pb_assert_canonical_utc_seconds "$network_plan" 'Prod network plan timestamps' \
  '["observedAt"]' '["expiresAt"]'
pb_assert_canonical_utc_seconds "$capacity_input" 'Prod design capacity timestamps' \
  '["observedAt"]' '["expiresAt"]'

PLATFORM_CHECK_DETAIL_ONLY=true bash "$SCRIPT_DIR/dev-ready-check.sh" "$deployment" "$slo" "$ready" >/dev/null

pb_assert_json "$network_plan" '
  keys == ["accountId","billableResources","environment","evidenceGrade","expiresAt","network","observedAt","ownerId","region","savedPlan","schemaVersion"] and
  .schemaVersion == "playbuilder.prod-network-plan/v1" and .evidenceGrade == "STATIC" and
  .ownerId == $ENV.OWNER_ID and .accountId == $ENV.AWS_ACCOUNT_ID and
  .environment == "prod" and .region == $ENV.AWS_REGION and
  (.savedPlan | keys == ["path","sha256"]) and (.savedPlan.path | type == "string" and length > 0) and
  (.savedPlan.sha256 | test("^sha256:[0-9a-f]{64}$")) and
  (.network | keys == ["availabilityZones","natGatewayCount","vpcCidr"]) and
  (.network.vpcCidr | test("^[0-9.]+/[0-9]+$")) and
  (.network.availabilityZones | type == "array" and length >= 2 and all(startswith($ENV.AWS_REGION))) and
  (.network.natGatewayCount | type == "number" and floor == . and . > 0) and
  (.billableResources | type == "array" and length > 0 and all(type == "string" and length > 0)) and
  (.observedAt | fromdateiso8601) <= now and now < (.expiresAt | fromdateiso8601)
' 'invalid Prod network saved-plan summary'

plan_path=$(jq -r '.savedPlan.path' "$network_plan")
[[ -f "$plan_path" ]] || pb_fail "saved network plan not found: $plan_path" 66
plan_digest=$(pb_sha256_file "$plan_path")
[[ "$plan_digest" == "$(jq -r '.savedPlan.sha256' "$network_plan")" ]] || pb_fail 'NETWORK_PLAN_DIGEST_MISMATCH'

jq -e --arg owner "$OWNER_ID" --arg account "$AWS_ACCOUNT_ID" --arg region "$AWS_REGION" '
  .mode == "design" and .ownerId == $owner and .accountId == $account and .region == $region
' "$capacity_input" >/dev/null || pb_fail 'design capacity identity mismatch'

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
PLATFORM_CHECK_DETAIL_ONLY=true bash "$SCRIPT_DIR/capacity-check.sh" --mode design --input "$capacity_input" \
  --output "$tmp_dir/capacity-decision.json" >/dev/null

issued_at=$(pb_now)
expires_at=$(pb_expires_after "${PREFLIGHT_TTL_SECONDS:-3600}")
payload=$(jq -n \
  --arg owner "$OWNER_ID" --arg account "$AWS_ACCOUNT_ID" --arg region "$AWS_REGION" \
  --arg deployment_sha "$(pb_sha256_file "$deployment")" \
  --arg slo_sha "$(pb_sha256_file "$slo")" \
  --arg ready_sha "$(pb_sha256_file "$ready")" \
  --arg plan_sha "$plan_digest" --arg capacity_sha "$(pb_sha256_file "$capacity_input")" \
  --arg issued "$issued_at" --arg expires "$expires_at" '
  {
    schemaVersion:"playbuilder.prod-preflight/v1", evidenceGrade:"STATIC", stage:"design", decision:"GO",
    ownerId:$owner, accountId:$account, region:$region,
    bindings:{
      devDeploymentSha256:$deployment_sha, devSloSha256:$slo_sha, devReadySha256:$ready_sha,
      savedPlanSha256:$plan_sha, capacityInputSha256:$capacity_sha, previousDecisionSha256:null
    },
    issuedAt:$issued, expiresAt:$expires
  }
')
pb_write_json "$output" "$payload"
echo 'PASS: [STATIC] Prod pre-network design and capacity decision is GO.'
