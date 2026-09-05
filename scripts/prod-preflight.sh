#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/evidence-common.sh"

if [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then
  [[ -d "$COURSE_CHECK_BIN_DIR" ]] || course_fail 'COURSE_CHECK_BIN_DIR is not a directory' 64
  PATH="$COURSE_CHECK_BIN_DIR:$PATH"
fi

[[ $# -eq 7 ]] || course_fail 'usage: prod-preflight.sh <dev-deployment.json> <dev-slo.json> <dev-ready.json> <design-decision.json> <eks-plan-summary.json> <capacity-input.json> <output.json>' 64
deployment=$1
slo=$2
ready=$3
design_decision=$4
eks_plan=$5
capacity_input=$6
output=$7
for name in COURSE_ID AWS_ACCOUNT_ID AWS_REGION AWS_PROFILE FINOPS_CONTRACT_JSON PLATFORM_INSTANCE_ID FINOPS_GATE_POLICY; do [[ -n "${!name:-}" ]] || course_fail "$name is required" 64; done
course_validate_region "$AWS_REGION"
course_validate_account "$AWS_ACCOUNT_ID"
for file in "$design_decision" "$eks_plan" "$capacity_input"; do course_require_file "$file"; done
course_assert_canonical_utc_seconds "$design_decision" 'Prod design decision timestamps' \
  '["issuedAt"]' '["expiresAt"]'
course_assert_canonical_utc_seconds "$eks_plan" 'Prod EKS plan timestamps' \
  '["observedAt"]' '["expiresAt"]'
course_assert_canonical_utc_seconds "$capacity_input" 'Prod estimate capacity timestamps' \
  '["observedAt"]' '["expiresAt"]'

COURSE_CHECK_DETAIL_ONLY=true bash "$SCRIPT_DIR/dev-ready-check.sh" "$deployment" "$slo" "$ready" >/dev/null
ready_digest=$(course_sha256_file "$ready")
course_assert_json "$design_decision" '
  keys == ["accountId","bindings","courseId","decision","evidenceGrade","expiresAt","issuedAt","region","schemaVersion","stage"] and
  .schemaVersion == "course.prod-preflight/v1" and .evidenceGrade == "STATIC" and
  .stage == "design" and .decision == "GO" and .courseId == $ENV.COURSE_ID and
  .accountId == $ENV.AWS_ACCOUNT_ID and .region == $ENV.AWS_REGION and
  (.bindings | keys == ["capacityInputSha256","devDeploymentSha256","devReadySha256","devSloSha256","previousDecisionSha256","savedPlanSha256"]) and
  .bindings.previousDecisionSha256 == null and
  (.issuedAt | fromdateiso8601) <= now and now < (.expiresAt | fromdateiso8601)
' 'invalid or expired design decision'
[[ $(jq -r '.bindings.devReadySha256' "$design_decision") == "$ready_digest" ]] || course_fail 'DESIGN_DEV_READY_DIGEST_MISMATCH'

course_assert_json "$eks_plan" '
  keys == ["accountId","courseId","environment","evidenceGrade","expiresAt","maxPodsPerNode","nodeGroups","observedAt","region","savedPlan","schemaVersion","subnetIds"] and
  .schemaVersion == "course.prod-eks-plan/v1" and .evidenceGrade == "STATIC" and
  .courseId == $ENV.COURSE_ID and .accountId == $ENV.AWS_ACCOUNT_ID and
  .environment == "prod" and .region == $ENV.AWS_REGION and
  (.savedPlan | keys == ["path","sha256"]) and (.savedPlan.sha256 | test("^sha256:[0-9a-f]{64}$")) and
  (.nodeGroups | type == "array" and length > 0 and all(
    keys == ["desiredCount","instanceType"] and (.instanceType | type == "string" and length > 0) and
    (.desiredCount | type == "number" and floor == . and . > 0))) and
  (.subnetIds | type == "array" and length >= 2 and all(test("^subnet-"))) and
  (.maxPodsPerNode | type == "number" and floor == . and . > 0) and
  (.observedAt | fromdateiso8601) <= now and now < (.expiresAt | fromdateiso8601)
' 'invalid Prod EKS saved-plan summary'

plan_path=$(jq -r '.savedPlan.path' "$eks_plan")
[[ -f "$plan_path" ]] || course_fail "saved EKS plan not found: $plan_path" 66
plan_digest=$(course_sha256_file "$plan_path")
[[ "$plan_digest" == "$(jq -r '.savedPlan.sha256' "$eks_plan")" ]] || course_fail 'EKS_PLAN_DIGEST_MISMATCH'

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
finops_mode=collect
finops_access=()
if [[ -n "${FINOPS_FIXTURE_JSON:-}" ]]; then
  [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]] || course_fail 'FinOps fixture requires explicit static test mode'
  finops_mode=fixture
  finops_access=(--observations "$FINOPS_FIXTURE_JSON")
else
  [[ -z "${COURSE_CHECK_BIN_DIR:-}" ]] || course_fail 'static preflight must use FinOps fixture observations'
  if [[ -n "${FINOPS_BILLING_PROFILE:-}" && -z "${FINOPS_BILLING_ROLE_ARN:-}" ]]; then
    finops_access=(--profile "$FINOPS_BILLING_PROFILE")
  elif [[ -n "${FINOPS_BILLING_ROLE_ARN:-}" && -z "${FINOPS_BILLING_PROFILE:-}" ]]; then
    finops_access=(--role-arn "$FINOPS_BILLING_ROLE_ARN")
  else
    course_fail 'select one explicit FINOPS_BILLING_PROFILE or FINOPS_BILLING_ROLE_ARN'
  fi
fi
bash "$SCRIPT_DIR/finops-readiness-check.sh" "$finops_mode" --contract "$FINOPS_CONTRACT_JSON" \
  --account "$AWS_ACCOUNT_ID" --region "$AWS_REGION" --platform-id "$PLATFORM_INSTANCE_ID" \
  --gate-policy "$FINOPS_GATE_POLICY" "${finops_access[@]}" --output "$tmp_dir/finops-readiness.json" >/dev/null

instance_types=()
while IFS= read -r value; do instance_types+=("$value"); done < <(jq -r '[.nodeGroups[].instanceType] | unique[]' "$eks_plan")
subnet_ids=()
while IFS= read -r value; do subnet_ids+=("$value"); done < <(jq -r '.subnetIds[]' "$eks_plan")
instance_json=$(aws ec2 describe-instance-types --instance-types "${instance_types[@]}" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" --output json)
subnet_json=$(aws ec2 describe-subnets --subnet-ids "${subnet_ids[@]}" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" --output json)

jq -en --argjson plan "$(jq -c . "$eks_plan")" --argjson instance "$instance_json" '
  ($plan.nodeGroups | all(.instanceType as $type | any($instance.InstanceTypes[]; .InstanceType == $type)))
' >/dev/null || course_fail 'INSTANCE_CAPACITY_NOT_FOUND'
jq -en --argjson plan "$(jq -c . "$eks_plan")" --argjson subnet "$subnet_json" '
  ($plan.subnetIds | all(. as $id | any($subnet.Subnets[]; .SubnetId == $id and (.AvailableIpAddressCount | type == "number"))))
' >/dev/null || course_fail 'SUBNET_CAPACITY_NOT_FOUND'

derived=$(jq -n --argjson plan "$(jq -c . "$eks_plan")" --argjson instance "$instance_json" --argjson subnet "$subnet_json" '
  reduce $plan.nodeGroups[] as $group (
    {count:0,totalCpuMilli:0,totalMemoryMiB:0,totalPodSlots:0,minMaxPodsPerNode:$plan.maxPodsPerNode};
    ($instance.InstanceTypes[] | select(.InstanceType == $group.instanceType)) as $shape |
    .count += $group.desiredCount |
    .totalCpuMilli += ($group.desiredCount * $shape.VCpuInfo.DefaultVCpus * 1000) |
    .totalMemoryMiB += ($group.desiredCount * $shape.MemoryInfo.SizeInMiB) |
    .totalPodSlots += ($group.desiredCount * $plan.maxPodsPerNode)
  ) |
  . + {subnetAvailableIps:([$subnet.Subnets[].AvailableIpAddressCount] | add)}
')
jq -e --argjson derived "$derived" --arg course "$COURSE_ID" --arg account "$AWS_ACCOUNT_ID" --arg region "$AWS_REGION" '
  .mode == "estimate" and .courseId == $course and .accountId == $account and .region == $region and
  .nodes == ($derived | del(.subnetAvailableIps)) and .network.subnetAvailableIps == $derived.subnetAvailableIps
' "$capacity_input" >/dev/null || course_fail 'ESTIMATE_CAPACITY_DOES_NOT_MATCH_COLLECTED_SHAPE'

COURSE_CHECK_DETAIL_ONLY=true bash "$SCRIPT_DIR/capacity-check.sh" --mode estimate --input "$capacity_input" \
  --output "$tmp_dir/capacity-decision.json" >/dev/null

grade=$(course_runtime_grade)
issued_at=$(course_now)
expires_at=$(course_expires_after "${PREFLIGHT_TTL_SECONDS:-3600}")
payload=$(jq -n \
  --arg grade "$grade" --arg course "$COURSE_ID" --arg account "$AWS_ACCOUNT_ID" --arg region "$AWS_REGION" \
  --arg deployment_sha "$(course_sha256_file "$deployment")" --arg slo_sha "$(course_sha256_file "$slo")" \
  --arg ready_sha "$ready_digest" --arg plan_sha "$plan_digest" \
  --arg capacity_sha "$(course_sha256_file "$capacity_input")" \
  --arg previous_sha "$(course_sha256_file "$design_decision")" \
  --argjson finops "$(jq -c . "$tmp_dir/finops-readiness.json")" \
  --arg issued "$issued_at" --arg expires "$expires_at" '
  {
    schemaVersion:"course.prod-preflight/v2", evidenceGrade:$grade, stage:"estimate", decision:"GO", finops:$finops,
    courseId:$course, accountId:$account, region:$region,
    bindings:{
      devDeploymentSha256:$deployment_sha, devSloSha256:$slo_sha, devReadySha256:$ready_sha,
      savedPlanSha256:$plan_sha, capacityInputSha256:$capacity_sha, previousDecisionSha256:$previous_sha,
      finopsContractSha256:$finops.bindings.contractSha256
    },
    issuedAt:$issued, expiresAt:$expires
  }
')
course_write_json "$output" "$payload"
if [[ "$grade" == STATIC ]]; then
  echo 'PASS: [STATIC] SIMULATED_CLOUD_CONTRACT Prod pre-EKS estimate is GO.'
else
  echo 'PASS: [CLOUD_RUNTIME] Prod pre-EKS estimate is GO.'
fi
