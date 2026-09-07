#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixtures="$root/tests/fixtures"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$1 $2" == "run list" ]]; then
  cat "$PLATFORM_CHECK_RUNS_FIXTURE"
elif [[ "$1 $2" == "run watch" ]]; then
  exit 0
elif [[ "$1 $2" == "run view" ]]; then
  run_id=$3
  jq --argjson id "$run_id" --arg sha "$PLATFORM_CHECK_HEAD_SHA" --arg workflow "${PLATFORM_CHECK_WORKFLOW_NAME:-CI}" '
    {databaseId:$id,headSha:$sha,workflowName:$workflow,event:"push",status:"completed",conclusion:"success",url:"https://example.invalid/run/\($id)"}
  ' <<<'{}'
elif [[ "$1" == "api" ]]; then
  endpoint=${!#}
  case "$endpoint" in
    repos/owner/EKS-infra|repos/owner/mini-commerce)
      repository_name=${endpoint##*/}
      jq -n --arg name "$repository_name" '{owner:{login:"owner",id:101},name:$name,id:202}'
      ;;
    repos/owner/EKS-infra/actions/oidc/customization/sub|repos/owner/mini-commerce/actions/oidc/customization/sub)
      echo '{"use_immutable_subject":true}'
      ;;
    repos/owner/argocd-gitops/rulesets)
      echo '[{"id":42,"name":"main-protection","enforcement":"active","target":"branch"}]'
      ;;
    repos/owner/argocd-gitops/rulesets/42)
      echo '{"bypass_actors":[],"rules":[{"type":"pull_request","parameters":{"require_code_owner_review":true}},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"validate"}]}}]}'
      ;;
    *)
      printf 'unexpected gh api endpoint: %s\n' "$endpoint" >&2
      exit 97
      ;;
  esac
else
  printf 'unexpected gh invocation: %q ' "$@" >&2
  exit 97
fi
EOF

cat >"$tmp_dir/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
: "${PLATFORM_FAKE_AWS_LOG:?}"
printf '%s\n' "$*" >>"$PLATFORM_FAKE_AWS_LOG"
profile=""
previous=""
for argument in "$@"; do
  [[ "$previous" == "--profile" ]] && profile=$argument
  previous=$argument
done
case "$profile" in
  network) account_id=111111111111; account_role=network ;;
  dev) account_id=222222222222; account_role=dev ;;
  *) printf 'unexpected aws profile: %s\n' "$profile" >&2; exit 97 ;;
esac
case "$1 $2" in
  'sts get-caller-identity')
    jq -n --arg account "$account_id" '{Account:$account,Arn:("arn:aws:iam::"+$account+":user/mini-commerce")}'
    ;;
  's3api get-bucket-tagging')
    if [[ "${PLATFORM_FAKE_CASE:-}" == "bucket-environment-mismatch" && "$account_role" == "dev" ]]; then
      account_role=network
    fi
    jq -n --arg account_role "$account_role" \
      '{TagSet:[{Key:"ManagedBy",Value:"Terraform"},{Key:"Project",Value:"mini-commerce"},{Key:"Environment",Value:$account_role}]}'
    ;;
  's3api get-bucket-location')
    if [[ "$AWS_REGION" == "us-east-1" ]]; then
      echo '{"LocationConstraint":null}'
    else
      jq -n --arg region "$AWS_REGION" '{LocationConstraint:$region}'
    fi
    ;;
  's3api get-bucket-versioning') echo '{"Status":"Enabled"}' ;;
  's3api get-bucket-encryption')
    echo '{"ServerSideEncryptionConfiguration":{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}}'
    ;;
  's3api get-public-access-block')
    echo '{"PublicAccessBlockConfiguration":{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}}'
    ;;
  'route53 list-hosted-zones-by-name')
    if [[ "$account_role" == "network" ]]; then
      echo '{"HostedZones":[{"Id":"/hostedzone/ZAPEX","Name":"example.com.","Config":{"PrivateZone":false}},{"Id":"/hostedzone/ZOTHER","Name":"example.org.","Config":{"PrivateZone":false}}]}'
    else
      echo '{"HostedZones":[{"Id":"/hostedzone/ZDEVPRIVATE","Name":"dev.example.com.","Config":{"PrivateZone":true}},{"Id":"/hostedzone/ZDEV","Name":"dev.example.com.","Config":{"PrivateZone":false}}]}'
    fi
    ;;
  'route53 get-hosted-zone')
    if [[ "$account_role" == "network" ]]; then
      echo '{"DelegationSet":{"NameServers":["ns-1.example.net.","ns-2.example.net."]}}'
    else
      echo '{"DelegationSet":{"NameServers":["ns-dev-1.example.net.","ns-dev-2.example.net."]}}'
    fi
    ;;
  'route53 list-resource-record-sets')
    case "${PLATFORM_FAKE_CASE:-}" in
      delegation-missing)
        echo '{"ResourceRecordSets":[{"Name":"dev.example.com.","Type":"A","TTL":300,"ResourceRecords":[{"Value":"192.0.2.1"}]}]}' ;;
      delegation-mismatch)
        echo '{"ResourceRecordSets":[{"Name":"dev.example.com.","Type":"NS","TTL":300,"ResourceRecords":[{"Value":"ns-stale-1.example.net."},{"Value":"ns-dev-2.example.net."}]}]}' ;;
      *)
        echo '{"ResourceRecordSets":[{"Name":"dev.example.com.","Type":"NS","TTL":300,"ResourceRecords":[{"Value":"NS-DEV-1.example.net."},{"Value":"ns-dev-2.example.net"}]}]}' ;;
    esac
    ;;
  'iam list-open-id-connect-providers')
    if [[ "${PLATFORM_FAKE_CASE:-}" == "duplicate-dev-oidc" && "$account_role" == "dev" ]]; then
      jq -n --arg account "$account_id" '{OpenIDConnectProviderList:[{Arn:("arn:aws:iam::"+$account+":oidc-provider/token.actions.githubusercontent.com")},{Arn:("arn:aws:iam::"+$account+":oidc-provider/token.actions.githubusercontent.com/duplicate")}]}'
    else
      jq -n --arg account "$account_id" '{OpenIDConnectProviderList:[{Arn:("arn:aws:iam::"+$account+":oidc-provider/token.actions.githubusercontent.com")}]}'
    fi
    ;;
  'iam get-open-id-connect-provider')
    echo '{"Url":"token.actions.githubusercontent.com","ClientIDList":["sts.amazonaws.com"]}'
    ;;
  *)
    printf 'unexpected aws invocation: %s\n' "$*" >&2
    exit 97
    ;;
esac
EOF

cat >"$tmp_dir/bin/dig" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${PLATFORM_FAKE_CASE:-}:${!#}" in
  public-child-mismatch:dev.example.com) printf '%s\n' ns-other-1.example.net. ns-other-2.example.net. ;;
  public-apex-mismatch:example.com) printf '%s\n' ns-1.example.net. ns-9.example.net. ;;
  dig-failure:dev.example.com) echo ';; connection timed out; no servers could be reached' >&2; exit 9 ;;
  *:example.com) printf '%s\n' ns-1.example.net. ns-2.example.net. ;;
  *:dev.example.com) printf '%s\n' ns-dev-2.example.net. ns-dev-1.example.net. ;;
  *) printf 'unexpected dig query: %s\n' "$*" >&2; exit 97 ;;
esac
EOF
chmod +x "$tmp_dir/bin/gh" "$tmp_dir/bin/aws" "$tmp_dir/bin/dig"

for region in ap-northeast-2 us-east-1; do
  aws_log="$tmp_dir/aws-ch02-$region.log"
  : >"$aws_log"
  PLATFORM_CHECK_BIN_DIR="$tmp_dir/bin" PLATFORM_FAKE_AWS_LOG="$aws_log" \
    NETWORK_AWS_PROFILE=network DEV_AWS_PROFILE=dev AWS_REGION="$region" LAB_PROJECT_NAME=mini-commerce \
    ROOT_DOMAIN=example.com INFRA_GH_REPO=owner/EKS-infra \
    APP_GH_REPO=owner/mini-commerce GITOPS_GH_REPO=owner/argocd-gitops \
    bash "$root/scripts/foundation-check.sh" >"$tmp_dir/ch02-$region.out"
  [[ $(grep -Ec 'PASS: \[STATIC\]' "$tmp_dir/ch02-$region.out") -eq 1 ]]
  # Per-account state buckets derive from the profile account ID, never from STATE_BUCKET_NAME.
  grep -Fq 'STATE_BUCKET[network]=mini-commerce-tfstate-111111111111' "$tmp_dir/ch02-$region.out"
  grep -Fq 'STATE_BUCKET[dev]=mini-commerce-tfstate-222222222222' "$tmp_dir/ch02-$region.out"
  grep -Fq 'GITHUB_OIDC_ARN[network]=arn:aws:iam::111111111111:' "$tmp_dir/ch02-$region.out"
  grep -Fq 'GITHUB_OIDC_ARN[dev]=arn:aws:iam::222222222222:' "$tmp_dir/ch02-$region.out"
  grep -Fq 'IMMUTABLE_MAIN_SUB[owner/mini-commerce]=repo:owner@101/mini-commerce@202:ref:refs/heads/main' "$tmp_dir/ch02-$region.out"
  grep -Fq 'IMMUTABLE_MAIN_SUB[owner/EKS-infra]=repo:owner@101/EKS-infra@202:ref:refs/heads/main' "$tmp_dir/ch02-$region.out"
  # 2 accounts x (sts + 5 bucket checks) + apex (lookup, zone) + child (lookup, zone, apex NS record) + 2 x (oidc list, get)
  [[ $(wc -l <"$aws_log" | tr -d ' ') -eq 21 ]]
  [[ $(grep -c -- '--profile network ' "$aws_log") -eq 11 ]]
  [[ $(grep -c -- '--profile dev ' "$aws_log") -eq 10 ]]
  grep -Fq -- 'route53 list-resource-record-sets --hosted-zone-id ZAPEX --start-record-name dev.example.com --start-record-type NS' "$aws_log"
  grep -Fq -- 'route53 get-hosted-zone --id ZDEV --profile dev' "$aws_log"
  while IFS= read -r invocation; do
    if [[ " $invocation " != *" --region $region "* ]]; then
      printf 'AWS lookup omitted selected Region: %s\n' "$invocation" >&2
      exit 1
    fi
  done <"$aws_log"
done

# Every per-account comparison must be able to fail: each case flips one fake response or input.
expect_ch02_fail() {
  local label=$1 expected_text=$2 output status
  shift 2
  set +e
  output=$(env PLATFORM_CHECK_BIN_DIR="$tmp_dir/bin" PLATFORM_FAKE_AWS_LOG="$tmp_dir/aws-negative.log" \
    NETWORK_AWS_PROFILE=network DEV_AWS_PROFILE=dev AWS_REGION=ap-northeast-2 LAB_PROJECT_NAME=mini-commerce \
    ROOT_DOMAIN=example.com INFRA_GH_REPO=owner/EKS-infra APP_GH_REPO=owner/mini-commerce GITOPS_GH_REPO=owner/argocd-gitops \
    "$@" bash "$root/scripts/foundation-check.sh" 2>&1)
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || { printf 'ch02 negative case passed unexpectedly: %s\n' "$label" >&2; exit 1; }
  grep -Fq "$expected_text" <<<"$output" || {
    printf 'ch02 negative case %s did not report the expected diagnostic\n%s\n' "$label" "$output" >&2
    exit 1
  }
  ! grep -Fq 'PASS: [' <<<"$output"
}

expect_ch02_fail same-profile 'NETWORK_AWS_PROFILE과 DEV_AWS_PROFILE은 서로 다른 계정 profile이어야 합니다.' DEV_AWS_PROFILE=network
expect_ch02_fail uppercase-root-domain 'ROOT_DOMAIN은 trailing dot이 없는 소문자 도메인이어야 합니다' ROOT_DOMAIN=Example.com
expect_ch02_fail trailing-dot-root-domain 'ROOT_DOMAIN은 trailing dot이 없는 소문자 도메인이어야 합니다' ROOT_DOMAIN=example.com.
expect_ch02_fail bucket-environment-mismatch 'state bucket ownership tag가 일치하지 않습니다(account=dev)' PLATFORM_FAKE_CASE=bucket-environment-mismatch
expect_ch02_fail public-apex-mismatch 'Route 53 지정 nameserver와 public DNS 응답이 다릅니다.' PLATFORM_FAKE_CASE=public-apex-mismatch
expect_ch02_fail delegation-missing 'NS 위임 record가 없습니다' PLATFORM_FAKE_CASE=delegation-missing
expect_ch02_fail delegation-mismatch 'NS 위임 record가 child zone nameserver와 다릅니다.' PLATFORM_FAKE_CASE=delegation-mismatch
expect_ch02_fail public-child-mismatch 'child zone nameserver와 public DNS dev.example.com NS 응답이 다릅니다.' PLATFORM_FAKE_CASE=public-child-mismatch
expect_ch02_fail dig-failure 'public DNS dev.example.com NS 조회에 실패했습니다(dig exit=9).' PLATFORM_FAKE_CASE=dig-failure
expect_ch02_fail duplicate-dev-oidc 'GitHub OIDC provider는 dev 계정에 정확히 1개여야 합니다(found=2).' PLATFORM_FAKE_CASE=duplicate-dev-oidc

echo 'PASS: foundation state, DNS delegation and immutable OIDC boundaries'
