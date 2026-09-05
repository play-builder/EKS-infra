#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
variables="$root/environments/prod/02-eks/variables.tf"

rg -Uq 'variable "cluster_endpoint_public_access" \{[\s\S]*?default[[:space:]]*=[[:space:]]*false' "$variables"
grep -q 'variable "operator_access"' "$variables"
test -f "$root/scripts/prod-operator-access-check.sh"
rg -q 'associate_public_ip_address[[:space:]]*=[[:space:]]*false' "$root/modules/compute/operator-access/main.tf"
rg -q 'http_tokens[[:space:]]*=[[:space:]]*"required"' "$root/modules/compute/operator-access/main.tf"
! rg -q 'key_name[[:space:]]*=' "$root/modules/compute/operator-access/main.tf"
rg -q 'user_data[[:space:]]*=' "$root/modules/compute/operator-access/main.tf"
rg -q 'aws_eks_access_policy_association' "$root/modules/compute/operator-access/main.tf"

bash "$root/scripts/prod-operator-access-check.sh" --validate-only \
  --evidence "$root/tests/fixtures/operator-access-valid.json" >/dev/null
set +e
output=$(bash "$root/scripts/prod-operator-access-check.sh" --validate-only \
  --evidence "$root/tests/fixtures/operator-access-invalid-mode.json" 2>&1)
check_status=$?
set -e
[[ "$check_status" -ne 0 ]] && grep -Fq 'OPERATOR_ACCESS_MODE_INVALID' <<<"$output"

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin" "$tmp_dir/evidence"
cat >"$tmp_dir/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$FAKE_AWS_LOG"
case "$1 $2" in
  'sts get-caller-identity') printf '{"Account":"123456789012"}\n' ;;
  'ssm describe-instance-information') printf 'Online\n' ;;
  'ssm send-command') printf 'command-123\n' ;;
  'ssm wait') ;;
  'ssm get-command-invocation')
    output=$(printf 'CALLER_ARN=%s\nCLUSTER_ARN=%s\nAUTHORIZATION=yes\n' "$EXPECTED_CALLER" "$EXPECTED_CLUSTER")
    jq -n --arg output "$output" \
      '{Status:"Success",StandardOutputContent:$output,StandardErrorContent:""}'
    ;;
  *) echo "unexpected aws invocation: $*" >&2; exit 97 ;;
esac
EOF
chmod +x "$tmp_dir/bin/aws"
: >"$tmp_dir/aws.log"
cluster=arn:aws:eks:ap-northeast-2:123456789012:cluster/prod-platform-eks
role=arn:aws:iam::123456789012:role/prod-platform-eks-operator
caller=arn:aws:sts::123456789012:assumed-role/prod-platform-eks-operator/platform-operator-check
PATH="$tmp_dir/bin:$PATH" FAKE_AWS_LOG="$tmp_dir/aws.log" EXPECTED_CALLER="$caller" EXPECTED_CLUSTER="$cluster" \
  AWS_PROFILE=platform AWS_REGION=ap-northeast-2 bash "$root/scripts/prod-operator-access-check.sh" \
    --execute --evidence "$tmp_dir/evidence/operator.json" --cluster-arn "$cluster" \
    --operator-role-arn "$role" --instance-id i-0123456789abcdef0
jq -e --arg role "$role" --arg cluster "$cluster" '
  .operatorRoleArn == $role and .clusterArn == $cluster and .commands.ssmCommand == "Success" and
  .commands.kubectlAuthorization == "yes"
' "$tmp_dir/evidence/operator.json" >/dev/null
grep -Fq 'ssm send-command' "$tmp_dir/aws.log"
grep -Fq 'aws sts assume-role' "$tmp_dir/aws.log"
grep -Fq 'aws eks update-kubeconfig' "$tmp_dir/aws.log"
grep -Fq 'kubectl auth can-i get pods -n platform-system' "$tmp_dir/aws.log"

: >"$tmp_dir/aws.log"
set +e
output=$(PATH="$tmp_dir/bin:$PATH" FAKE_AWS_LOG="$tmp_dir/aws.log" \
  EXPECTED_CALLER=arn:aws:sts::123456789012:assumed-role/wrong/platform-operator-check EXPECTED_CLUSTER="$cluster" \
  AWS_PROFILE=platform AWS_REGION=ap-northeast-2 bash "$root/scripts/prod-operator-access-check.sh" \
    --execute --evidence "$tmp_dir/evidence/wrong.json" --cluster-arn "$cluster" \
    --operator-role-arn "$role" --instance-id i-0123456789abcdef0 2>&1)
status=$?
set -e
[[ "$status" -ne 0 && "$output" == *OPERATOR_ACCESS_ROLE_MISMATCH* ]]

echo 'PASS: production operator access is private and SSM-only.'
