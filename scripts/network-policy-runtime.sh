#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then
  PATH="$COURSE_CHECK_BIN_DIR:$PATH"
fi

fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
[[ $# -eq 4 ]] || fail 'usage: network-policy-runtime.sh <context> <cluster-name> <standard|strict> <addon-lock.json>'
: "${AWS_PROFILE:?AWS_PROFILE is required}"
: "${AWS_REGION:?AWS_REGION is required}"
[[ "$AWS_REGION" == "ap-northeast-2" || "$AWS_REGION" == "us-east-1" ]] || fail 'UNSUPPORTED_REGION'

context=$1
cluster_name=$2
expected_mode=$3
lock_file=$4
[[ "$expected_mode" == standard || "$expected_mode" == strict ]] || fail 'invalid enforcing mode'
[[ -f "$lock_file" ]] || fail 'add-on lock file not found'

if [[ -z "${COURSE_CHECK_BIN_DIR:-}" ]]; then
  [[ $(jq -r '.verificationStatus' "$lock_file") == VERIFIED ]] || fail 'ADDON_LOCK_NOT_VERIFIED'
fi

addon=$(aws eks describe-addon --cluster-name "$cluster_name" --addon-name vpc-cni \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" --output json)
daemonset=$(kubectl --context "$context" -n kube-system get daemonset aws-node -o json)
locked_version=$(jq -r '.addonVersion' "$lock_file")
agent_name=$(jq -r '.networkPolicyAgent.containerName' "$lock_file")
agent_digest=$(jq -r '.networkPolicyAgent.imageDigest' "$lock_file")

jq -e --arg version "$locked_version" --arg mode "$expected_mode" '
  .addon.addonName == "vpc-cni" and .addon.addonVersion == $version and .addon.status == "ACTIVE" and
  (.addon.configurationValues | fromjson | .enableNetworkPolicy == "true" and .env.NETWORK_POLICY_ENFORCING_MODE == $mode)
' <<<"$addon" >/dev/null || fail 'VPC_CNI_ADDON_MISMATCH'

jq -e '
  .metadata.name == "aws-node" and .status.desiredNumberScheduled > 0 and
  .status.desiredNumberScheduled == .status.currentNumberScheduled and
  .status.desiredNumberScheduled == .status.updatedNumberScheduled and
  .status.desiredNumberScheduled == .status.numberReady
' <<<"$daemonset" >/dev/null || fail 'AWS_NODE_NOT_READY'

agent=$(jq -c --arg digest "$agent_digest" '
  [.spec.template.spec.containers[] | select(.image | endswith("@" + $digest))] |
  if length == 1 then .[0] else empty end
' <<<"$daemonset")
[[ -n "$agent" ]] || fail 'NETWORK_POLICY_AGENT_IMAGE_NOT_FOUND'
[[ $(jq -r '.name' <<<"$agent") == "$agent_name" ]] || fail 'NETWORK_POLICY_AGENT_NAME_MISMATCH'

while IFS= read -r required_arg; do
  jq -e --arg arg "$required_arg" '(.args // []) | index($arg) != null' <<<"$agent" >/dev/null || \
    fail "NETWORK_POLICY_AGENT_ARG_MISSING: $required_arg"
done < <(jq -r '.networkPolicyAgent.requiredArgs[]' "$lock_file")

jq -e --arg mode "$expected_mode" '
  any(.spec.template.spec.containers[];
    .name == "aws-node" and any(.env[]?; .name == "NETWORK_POLICY_ENFORCING_MODE" and .value == $mode))
' <<<"$daemonset" >/dev/null || fail 'AWS_NODE_ENFORCING_MODE_MISMATCH'

if [[ "${COURSE_CHECK_DETAIL_ONLY:-false}" == true ]]; then
  echo 'DETAIL: VPC CNI add-on and aws-node are ready.'
elif [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then
  echo 'PASS: [STATIC] SIMULATED_CLOUD_CONTRACT VPC CNI runtime shape is valid.'
else
  echo 'PASS: [CLOUD_RUNTIME] VPC CNI add-on and aws-node are ready.'
fi
