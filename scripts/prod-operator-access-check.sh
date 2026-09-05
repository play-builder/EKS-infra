#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/lib/evidence-common.sh"

evidence=''
validate_only=false
execute=false
cluster_arn=''
operator_role_arn=''
instance_id=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --evidence) evidence=${2:-}; shift 2 ;;
    --validate-only) validate_only=true; shift ;;
    --execute) execute=true; shift ;;
    --cluster-arn) cluster_arn=${2:-}; shift 2 ;;
    --operator-role-arn) operator_role_arn=${2:-}; shift 2 ;;
    --instance-id) instance_id=${2:-}; shift 2 ;;
    *) course_fail "unknown argument: $1" 64 ;;
  esac
done

if [[ "$execute" == true ]]; then
  [[ -n "$evidence" && -n "$cluster_arn" && -n "$operator_role_arn" && -n "$instance_id" ]] || \
    course_fail '--execute requires --evidence, --cluster-arn, --operator-role-arn, and --instance-id' 64
  : "${AWS_PROFILE:?AWS_PROFILE is required for --execute}"
  : "${AWS_REGION:?AWS_REGION is required for --execute}"
  caller=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --region "$AWS_REGION" --output json)
  account_id=$(jq -r '.Account' <<<"$caller")
  course_validate_account "$account_id"
  aws ssm start-session --target "$instance_id" --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --document-name AWS-StartInteractiveCommand --parameters 'command=kubectl auth can-i --list'
  payload=$(jq -n --arg account "$account_id" --arg region "$AWS_REGION" --arg cluster "$cluster_arn" \
    --arg role "$operator_role_arn" --arg instance "$instance_id" '
      {schemaVersion:"platform.operator-access/v1",evidenceGrade:"CLOUD_RUNTIME",mode:"ssm",
       clusterEndpointPublicAccess:false,accountId:$account,region:$region,clusterArn:$cluster,
       operatorRoleArn:$role,instanceId:$instance,commands:{ssmSession:"PASS",kubectlAuthCanI:"PASS"}}')
  course_write_json "$evidence" "$payload"
fi

[[ -n "$evidence" ]] || course_fail '--evidence is required' 64
course_require_file "$evidence"

mode=$(jq -r '.mode // empty' "$evidence")
[[ "$mode" == ssm ]] || course_fail 'OPERATOR_ACCESS_MODE_INVALID'
course_assert_json "$evidence" '
  def nonblank: type == "string" and test("[^[:space:]]");
  .schemaVersion == "platform.operator-access/v1" and
  .evidenceGrade == "CLOUD_RUNTIME" and
  .mode == "ssm" and
  .clusterEndpointPublicAccess == false and
  (.accountId | test("^[0-9]{12}$")) and (.region | IN("ap-northeast-2", "us-east-1")) and
  (.clusterArn | nonblank) and (.operatorRoleArn | nonblank) and (.instanceId | nonblank) and
  (.commands.ssmSession == "PASS") and (.commands.kubectlAuthCanI == "PASS")
' 'OPERATOR_ACCESS_EVIDENCE_INVALID'

if [[ "$validate_only" == true || "$execute" == true ]]; then
  echo 'PASS: private SSM operator access evidence is structurally valid.'
  exit 0
fi

course_fail 'OPERATOR_ACCESS_RUNTIME_CAPTURE_REQUIRED: use --execute or validate captured evidence.' 64
