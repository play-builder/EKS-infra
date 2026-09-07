#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/lib/evidence-common.sh"
pb_prepare_commands
API_VERSION="2026-03-10"

normalize_nameservers() {
  tr '[:space:]' '\n' \
    | awk 'NF { value=tolower($0); sub(/\.$/, "", value); print value }' \
    | sort -u
}

account_id_for_profile() {
  local profile=$1 identity account_id
  identity=$(aws sts get-caller-identity --profile "$profile" --region "$AWS_REGION" --output json)
  account_id=$(jq -r '.Account // empty' <<<"$identity")
  [[ "$account_id" =~ ^[0-9]{12}$ ]] || pb_fail "profile의 AWS 계정 ID를 확인하지 못했습니다: $profile"
  printf '%s\n' "$account_id"
}

check_state_bucket() {
  local profile=$1 region=$2 bucket=$3 project=$4 account_role=$5
  local tags location versioning encryption public_block

  tags=$(aws s3api get-bucket-tagging --bucket "$bucket" --profile "$profile" --region "$AWS_REGION" --output json)
  jq -e --arg project "$project" --arg account_role "$account_role" '
    any(.TagSet[]?; .Key == "ManagedBy" and .Value == "Terraform") and
    any(.TagSet[]?; .Key == "Project" and .Value == $project) and
    any(.TagSet[]?; .Key == "Environment" and .Value == $account_role)
  ' <<<"$tags" >/dev/null || pb_fail "state bucket ownership tag가 일치하지 않습니다(account=$account_role): $bucket"

  location=$(aws s3api get-bucket-location --bucket "$bucket" --profile "$profile" --region "$AWS_REGION" --output json)
  if [[ "$region" == "us-east-1" ]]; then
    jq -e '.LocationConstraint == null' <<<"$location" >/dev/null || \
      pb_fail "state bucket Region이 us-east-1이 아닙니다: $bucket"
  else
    jq -e --arg region "$region" '.LocationConstraint == $region' <<<"$location" >/dev/null || \
      pb_fail "state bucket Region이 일치하지 않습니다: $bucket"
  fi

  versioning=$(aws s3api get-bucket-versioning --bucket "$bucket" --profile "$profile" --region "$AWS_REGION" --output json)
  jq -e '.Status == "Enabled"' <<<"$versioning" >/dev/null || pb_fail "state bucket versioning이 Enabled가 아닙니다."

  encryption=$(aws s3api get-bucket-encryption --bucket "$bucket" --profile "$profile" --region "$AWS_REGION" --output json)
  jq -e 'any(.ServerSideEncryptionConfiguration.Rules[]?; .ApplyServerSideEncryptionByDefault.SSEAlgorithm == "AES256" or .ApplyServerSideEncryptionByDefault.SSEAlgorithm == "aws:kms")' \
    <<<"$encryption" >/dev/null || pb_fail "state bucket 기본 암호화가 없습니다."

  public_block=$(aws s3api get-public-access-block --bucket "$bucket" --profile "$profile" --region "$AWS_REGION" --output json)
  jq -e '.PublicAccessBlockConfiguration | .BlockPublicAcls and .IgnorePublicAcls and .BlockPublicPolicy and .RestrictPublicBuckets' \
    <<<"$public_block" >/dev/null || pb_fail "state bucket public access block 네 항목이 모두 true가 아닙니다."

  pb_detail "Terraform state bucket 보안 상태가 유효합니다(account=$account_role, bucket=$bucket)."
}

check_account_state_bucket() {
  local account_role=$1 profile=$2 account_id bucket
  account_id=$(account_id_for_profile "$profile")
  bucket="${PLATFORM_PROJECT_NAME}-tfstate-${account_id}"
  printf 'STATE_BUCKET[%s]=%s account_id=%s\n' "$account_role" "$bucket" "$account_id"
  check_state_bucket "$profile" "$AWS_REGION" "$bucket" "$PLATFORM_PROJECT_NAME" "$account_role"
}

find_public_hosted_zone() {
  local profile=$1 zone_name=$2 zones zone_id
  zones=$(aws route53 list-hosted-zones-by-name \
    --dns-name "$zone_name" --max-items 10 --profile "$profile" --region "$AWS_REGION" --output json)
  zone_id=$(jq -r --arg name "${zone_name}." '
    [.HostedZones[]? | select(.Name == $name and (.Config.PrivateZone // false) == false)]
    | if length == 1 then .[0].Id else empty end
  ' <<<"$zones")
  [[ -n "$zone_id" ]] || pb_fail "public hosted zone을 정확히 하나 찾지 못했습니다: $zone_name (profile=$profile)"
  printf '%s\n' "${zone_id#/hostedzone/}"
}

hosted_zone_nameservers() {
  local profile=$1 hosted_zone_id=$2
  aws route53 get-hosted-zone \
    --id "$hosted_zone_id" --profile "$profile" --region "$AWS_REGION" --output json \
    | jq -r '.DelegationSet.NameServers[]' \
    | normalize_nameservers
}

check_dns_delegation() {
  local profile=$1 hosted_zone_id=$2 root_domain=$3
  local route53_nameservers public_nameservers

  route53_nameservers=$(hosted_zone_nameservers "$profile" "$hosted_zone_id")
  public_nameservers=$(dig +short NS "$root_domain" | normalize_nameservers) || \
    pb_fail "public DNS $root_domain NS 조회에 실패했습니다(dig exit=$?)."

  [[ -n "$route53_nameservers" ]] || pb_fail "Route 53 nameserver 응답이 비어 있습니다."
  [[ -n "$public_nameservers" ]] || pb_fail "public DNS nameserver 응답이 비어 있습니다. registrar 위임을 확인하십시오."
  [[ "$route53_nameservers" == "$public_nameservers" ]] || \
    pb_fail "Route 53 지정 nameserver와 public DNS 응답이 다릅니다."

  printf 'DNS_NAMESERVERS[%s]:\n%s\n' "$root_domain" "$public_nameservers"
  pb_detail "apex DNS delegation이 일치합니다(domain=$root_domain, zone=$hosted_zone_id)."
}

check_child_zone_delegation() {
  local network_profile=$1 apex_zone_id=$2 child_profile=$3 child_zone_id=$4 child_domain=$5
  local child_nameservers delegation_nameservers public_nameservers

  child_nameservers=$(hosted_zone_nameservers "$child_profile" "$child_zone_id")
  [[ -n "$child_nameservers" ]] || pb_fail "child zone nameserver 응답이 비어 있습니다: $child_domain"

  delegation_nameservers=$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$apex_zone_id" --start-record-name "$child_domain" --start-record-type NS --max-items 1 \
    --profile "$network_profile" --region "$AWS_REGION" --output json \
    | jq -r --arg name "${child_domain}." \
      '.ResourceRecordSets[]? | select(.Name == $name and .Type == "NS") | .ResourceRecords[].Value' \
    | normalize_nameservers)
  [[ -n "$delegation_nameservers" ]] || \
    pb_fail "apex zone에 $child_domain NS 위임 record가 없습니다. 01-dns child_zones에 등록하십시오."
  [[ "$child_nameservers" == "$delegation_nameservers" ]] || \
    pb_fail "apex zone의 $child_domain NS 위임 record가 child zone nameserver와 다릅니다."

  public_nameservers=$(dig +short NS "$child_domain" | normalize_nameservers) || \
    pb_fail "public DNS $child_domain NS 조회에 실패했습니다(dig exit=$?)."
  [[ -n "$public_nameservers" ]] || pb_fail "public DNS $child_domain NS 응답이 비어 있습니다."
  [[ "$child_nameservers" == "$public_nameservers" ]] || \
    pb_fail "child zone nameserver와 public DNS $child_domain NS 응답이 다릅니다."

  printf 'DNS_NAMESERVERS[%s]:\n%s\n' "$child_domain" "$public_nameservers"
  pb_detail "child zone delegation이 일치합니다(domain=$child_domain, zone=$child_zone_id)."
}

find_github_oidc_provider() {
  local profile=$1 account_role=$2 provider_arns provider_arn provider_json count=0 selected=""
  provider_arns=$(aws iam list-open-id-connect-providers --profile "$profile" --region "$AWS_REGION" --output json \
    | jq -r '.OpenIDConnectProviderList[].Arn')

  while IFS= read -r provider_arn; do
    [[ -n "$provider_arn" ]] || continue
    provider_json=$(aws iam get-open-id-connect-provider \
      --open-id-connect-provider-arn "$provider_arn" --profile "$profile" --region "$AWS_REGION" --output json)
    if [[ "$(jq -r '.Url' <<<"$provider_json")" == "token.actions.githubusercontent.com" ]]; then
      count=$((count + 1))
      selected=$provider_arn
      jq -e 'any(.ClientIDList[]?; . == "sts.amazonaws.com")' <<<"$provider_json" >/dev/null || \
        pb_fail "GitHub OIDC provider에 sts.amazonaws.com audience가 없습니다."
    fi
  done <<<"$provider_arns"

  [[ "$count" -eq 1 ]] || pb_fail "GitHub OIDC provider는 $account_role 계정에 정확히 1개여야 합니다(found=$count)."
  printf 'GITHUB_OIDC_ARN[%s]=%s\n' "$account_role" "$selected"
  pb_detail "$account_role 계정의 GitHub OIDC provider가 유일하며 audience가 유효합니다."
}

check_immutable_subject() {
  local repository=$1 trusted_by=$2 metadata customization owner name owner_id repository_id subject
  metadata=$(gh api -H "X-GitHub-Api-Version: $API_VERSION" "repos/$repository")
  customization=$(gh api -H "X-GitHub-Api-Version: $API_VERSION" \
    "repos/$repository/actions/oidc/customization/sub")
  jq -e '.use_immutable_subject == true' <<<"$customization" >/dev/null || \
    pb_fail "$repository immutable OIDC subject가 활성화되지 않았습니다."

  owner=$(jq -r '.owner.login' <<<"$metadata")
  name=$(jq -r '.name' <<<"$metadata")
  owner_id=$(jq -r '.owner.id' <<<"$metadata")
  repository_id=$(jq -r '.id' <<<"$metadata")
  subject="repo:${owner}@${owner_id}/${name}@${repository_id}:ref:refs/heads/main"
  printf 'IMMUTABLE_MAIN_SUB[%s]=%s\n' "$repository" "$subject"
  pb_detail "$repository immutable main subject가 활성화됐습니다(trusted by $trusted_by)."
}

check_ruleset() {
  local repository=$1 rulesets ruleset_id detail
  rulesets=$(gh api -H "X-GitHub-Api-Version: $API_VERSION" "repos/$repository/rulesets")
  ruleset_id=$(jq -r '[.[] | select(.name == "main-protection" and .enforcement == "active" and .target == "branch")] | if length == 1 then .[0].id else empty end' \
    <<<"$rulesets")
  [[ -n "$ruleset_id" ]] || pb_fail "$repository active main-protection Ruleset을 정확히 하나 찾지 못했습니다."

  detail=$(gh api -H "X-GitHub-Api-Version: $API_VERSION" "repos/$repository/rulesets/$ruleset_id")
  jq -e '
    (.bypass_actors | length) == 0 and
    any(.rules[]?; .type == "pull_request" and .parameters.require_code_owner_review == true) and
    any(.rules[]?; .type == "required_status_checks" and
      any(.parameters.required_status_checks[]?; .context == "validate"))
  ' <<<"$detail" >/dev/null || pb_fail "$repository main-protection Ruleset 상세 조건이 일치하지 않습니다."

  pb_detail "GitHub main-protection Ruleset이 유효합니다(repository=$repository, id=$ruleset_id)."
}

check_secret_json() {
  local secret_file=$1 secret_class=$2 expected_keys=$3 secret_directory
  [[ -f "$secret_file" ]] || pb_fail "secret JSON 파일을 찾을 수 없습니다: $secret_file"
  secret_directory=$(cd "$(dirname "$secret_file")" && pwd -P)
  if git -C "$secret_directory" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    pb_fail "secret JSON은 Git worktree 밖에 두어야 합니다: $secret_file"
  fi
  jq -e --argjson expected_keys "$expected_keys" '
    type == "object" and
    (keys | sort == ($expected_keys | sort)) and
    all(.[]; type == "string" and length > 0)
  ' "$secret_file" >/dev/null || \
    pb_fail "$secret_class secret JSON은 $(jq -r --argjson keys "$expected_keys" '$keys | join(", ")' <<< '{}')만 포함해야 합니다."
  pb_detail "secret JSON key 구조가 유효하며 값은 출력하지 않았습니다."
}

check_secret_json_pair() {
  local runtime_file=${RUNTIME_SECRET_JSON_FILE:-}
  local database_file=${DB_SECRET_JSON_FILE:-}

  [[ -z "${SECRET_JSON_FILE:-}" ]] || \
    pb_fail "SECRET_JSON_FILE은 더 이상 지원하지 않습니다. RUNTIME_SECRET_JSON_FILE과 DB_SECRET_JSON_FILE을 사용하십시오." 64
  if [[ -n "$runtime_file" || -n "$database_file" ]]; then
    [[ -n "$runtime_file" && -n "$database_file" ]] || \
      pb_fail "RUNTIME_SECRET_JSON_FILE과 DB_SECRET_JSON_FILE은 함께 설정해야 합니다." 64
    check_secret_json "$runtime_file" runtime '["API_KEY"]'
    check_secret_json "$database_file" database '["DB_HOST","DB_PORT","DB_NAME","DB_USER","DB_PASSWORD"]'
  fi
}

check_foundation() {
  for command in aws dig gh git jq awk sort tr; do
    pb_require_command "$command"
  done
  for name in AWS_REGION PLATFORM_PROJECT_NAME NETWORK_AWS_PROFILE DEV_AWS_PROFILE ROOT_DOMAIN INFRA_GH_REPO APP_GH_REPO GITOPS_GH_REPO; do
    pb_require_environment "$name"
  done
  pb_validate_region "$AWS_REGION"
  [[ "$NETWORK_AWS_PROFILE" != "$DEV_AWS_PROFILE" ]] || \
    pb_fail "NETWORK_AWS_PROFILE과 DEV_AWS_PROFILE은 서로 다른 계정 profile이어야 합니다." 64
  [[ "$ROOT_DOMAIN" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || \
    pb_fail "ROOT_DOMAIN은 trailing dot이 없는 소문자 도메인이어야 합니다(01-dns root_domain과 동일): $ROOT_DOMAIN" 64

  local child_domain="dev.${ROOT_DOMAIN}" apex_zone_id child_zone_id

  # Terraform state bucket: one per account, named <project>-tfstate-<account id> by bootstrap/state-backend.
  check_account_state_bucket network "$NETWORK_AWS_PROFILE"
  check_account_state_bucket dev "$DEV_AWS_PROFILE"

  # DNS: apex zone in the network account, dev child zone delegated from it.
  apex_zone_id=$(find_public_hosted_zone "$NETWORK_AWS_PROFILE" "$ROOT_DOMAIN")
  check_dns_delegation "$NETWORK_AWS_PROFILE" "$apex_zone_id" "$ROOT_DOMAIN"
  child_zone_id=$(find_public_hosted_zone "$DEV_AWS_PROFILE" "$child_domain")
  check_child_zone_delegation "$NETWORK_AWS_PROFILE" "$apex_zone_id" "$DEV_AWS_PROFILE" "$child_zone_id" "$child_domain"

  # GitHub OIDC provider: exactly one per account.
  find_github_oidc_provider "$NETWORK_AWS_PROFILE" network
  find_github_oidc_provider "$DEV_AWS_PROFILE" dev

  # Immutable subjects: mini-commerce main -> network image push role, EKS-infra main -> dev infra role.
  check_immutable_subject "$APP_GH_REPO" "network 02-registry image push role"
  check_immutable_subject "$INFRA_GH_REPO" "dev bootstrap/ci-identity infra role"
  check_ruleset "$GITOPS_GH_REPO"
  check_secret_json_pair
  pb_detail "Foundation 계정별 state, DNS, identity, governance 계약이 유효합니다."
}

[[ $# -eq 0 ]] || pb_fail 'usage: foundation-check.sh (configure the documented environment inputs)' 64
check_foundation
pb_emit_pass 'Account state, DNS, identity and governance are valid.'
