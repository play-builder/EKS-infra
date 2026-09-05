#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
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
  course_validate_region "$AWS_REGION"
  course_assert_eks_cluster_arn "$cluster_arn" "$AWS_REGION" "$account_id"
  [[ "$operator_role_arn" =~ ^arn:aws(-[a-z]+)?:iam::${account_id}:role/[A-Za-z0-9+=,.@_/-]+$ ]] || \
    course_fail OPERATOR_ACCESS_ROLE_ARN_INVALID
  [[ "$instance_id" =~ ^i-[0-9a-f]{8,17}$ ]] || course_fail OPERATOR_ACCESS_INSTANCE_ID_INVALID

  ping_status=$(aws ssm describe-instance-information --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --filters "Key=InstanceIds,Values=$instance_id" --query 'InstanceInformationList[0].PingStatus' --output text)
  [[ "$ping_status" == Online ]] || course_fail OPERATOR_ACCESS_INSTANCE_OFFLINE

  cluster_name=${cluster_arn##*/}
  role_name=${operator_role_arn##*/}
  remote_command=$(cat <<EOF
set -Eeuo pipefail
read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<CREDS
\$(aws sts assume-role --role-arn '$operator_role_arn' --role-session-name platform-operator-check --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
CREDS
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
caller_arn=\$(aws sts get-caller-identity --query Arn --output text)
observed_cluster_arn=\$(aws eks describe-cluster --name '$cluster_name' --region '$AWS_REGION' --query cluster.arn --output text)
aws eks update-kubeconfig --name '$cluster_name' --region '$AWS_REGION' --kubeconfig /var/lib/amazon/ssm/operator-kubeconfig >/dev/null
authorization=\$(KUBECONFIG=/var/lib/amazon/ssm/operator-kubeconfig kubectl auth can-i get pods -n platform-system)
printf 'CALLER_ARN=%s\nCLUSTER_ARN=%s\nAUTHORIZATION=%s\n' "\$caller_arn" "\$observed_cluster_arn" "\$authorization"
EOF
)
  parameters=$(jq -cn --arg command "$remote_command" '{commands:[$command]}')
  command_id=$(aws ssm send-command --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --instance-ids "$instance_id" --document-name AWS-RunShellScript --parameters "$parameters" \
    --query Command.CommandId --output text)
  [[ "$command_id" =~ ^[A-Za-z0-9-]+$ ]] || course_fail OPERATOR_ACCESS_COMMAND_ID_INVALID
  aws ssm wait command-executed --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --command-id "$command_id" --instance-id "$instance_id"
  invocation=$(aws ssm get-command-invocation --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --command-id "$command_id" --instance-id "$instance_id" --output json)
  status=$(jq -r '.Status // empty' <<<"$invocation")
  [[ "$status" == Success ]] || course_fail OPERATOR_ACCESS_REMOTE_COMMAND_FAILED
  standard_error=$(jq -r '.StandardErrorContent // empty' <<<"$invocation")
  [[ -z "$standard_error" ]] || course_fail OPERATOR_ACCESS_REMOTE_STDERR_NOT_EMPTY
  standard_output=$(jq -r '.StandardOutputContent // empty' <<<"$invocation")
  caller_arn=$(awk -F= '/^CALLER_ARN=/{print substr($0,index($0,"=")+1); exit}' <<<"$standard_output")
  observed_cluster_arn=$(awk -F= '/^CLUSTER_ARN=/{print substr($0,index($0,"=")+1); exit}' <<<"$standard_output")
  authorization=$(awk -F= '/^AUTHORIZATION=/{print substr($0,index($0,"=")+1); exit}' <<<"$standard_output")
  [[ "$caller_arn" == "arn:aws:sts::$account_id:assumed-role/$role_name/platform-operator-check" ]] || \
    course_fail OPERATOR_ACCESS_ROLE_MISMATCH
  [[ "$observed_cluster_arn" == "$cluster_arn" ]] || course_fail OPERATOR_ACCESS_CLUSTER_MISMATCH
  [[ "$authorization" == yes ]] || course_fail OPERATOR_ACCESS_AUTHORIZATION_DENIED

  payload=$(jq -n --arg account "$account_id" --arg region "$AWS_REGION" --arg cluster "$cluster_arn" \
    --arg role "$operator_role_arn" --arg caller "$caller_arn" --arg instance "$instance_id" \
    --arg command "$command_id" --arg status "$status" --arg authorization "$authorization" '
      {schemaVersion:"platform.operator-access/v1",evidenceGrade:"CLOUD_RUNTIME",mode:"ssm",
       clusterEndpointPublicAccess:false,accountId:$account,region:$region,clusterArn:$cluster,
       operatorRoleArn:$role,callerArn:$caller,instanceId:$instance,
       commands:{ssmCommandId:$command,ssmCommand:$status,kubectlAuthorization:$authorization},
       observedAt:(now|todateiso8601)}')
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
  ((.commands.ssmCommand // .commands.ssmSession) == "Success" or
   (.commands.ssmCommand // .commands.ssmSession) == "PASS") and
  ((.commands.kubectlAuthorization // .commands.kubectlAuthCanI) == "yes" or
   (.commands.kubectlAuthorization // .commands.kubectlAuthCanI) == "PASS")
' 'OPERATOR_ACCESS_EVIDENCE_INVALID'

if [[ "$validate_only" == true || "$execute" == true ]]; then
  echo 'PASS: private SSM operator access evidence is structurally valid.'
  exit 0
fi

course_fail 'OPERATOR_ACCESS_RUNTIME_CAPTURE_REQUIRED: use --execute or validate captured evidence.' 64
