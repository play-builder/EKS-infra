#!/usr/bin/env bash
set -Eeuo pipefail

API_VERSION="2026-03-10"

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit "${2:-1}"
}

pass() {
  printf 'PASS: %s\n' "$1"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "필수 명령을 찾을 수 없습니다: $1" 127
}

require_environment() {
  local name=$1
  [[ -n "${!name:-}" ]] || fail "환경 변수가 필요합니다: $name" 64
}

check_ch01() {
  local repositories_root=${1:-}
  [[ -n "$repositories_root" && -d "$repositories_root" ]] || \
    fail "사용법: bash scripts/course-check.sh ch01 <three-repositories-root>" 64

  require_command git

  local name repository branch head origin_head dirty
  for name in EKS-infra argocd-gitops cicd-course-sample-app; do
    repository="$repositories_root/$name"
    [[ -d "$repository/.git" ]] || fail "Git repository를 찾을 수 없습니다: $repository" 66

    branch=$(git -C "$repository" branch --show-current)
    [[ "$branch" == "main" ]] || fail "$name branch가 main이 아닙니다: $branch"

    git -C "$repository" show-ref --verify --quiet refs/remotes/origin/main || \
      fail "$name origin/main 추적 ref가 없습니다. 먼저 git fetch origin main을 실행하십시오."
    head=$(git -C "$repository" rev-parse HEAD)
    origin_head=$(git -C "$repository" rev-parse refs/remotes/origin/main)
    [[ "$head" == "$origin_head" ]] || \
      fail "$name HEAD가 origin/main과 다릅니다: HEAD=$head origin/main=$origin_head"

    dirty=$(git -C "$repository" status --porcelain)
    [[ -z "$dirty" ]] || fail "$name worktree에 미커밋 변경이 있습니다."
    printf 'REPOSITORY: %s branch=%s sha=%s\n' "$name" "$branch" "$head"
  done

  pass "ch01 세 repository가 clean main이며 origin/main과 일치합니다."
}

normalize_nameservers() {
  tr '[:space:]' '\n' \
    | awk 'NF { value=tolower($0); sub(/\.$/, "", value); print value }' \
    | sort -u
}

check_state_bucket() {
  local profile=$1 region=$2 bucket=$3 project=$4
  local tags location versioning encryption public_block

  tags=$(aws s3api get-bucket-tagging --bucket "$bucket" --profile "$profile" --output json)
  jq -e --arg project "$project" '
    any(.TagSet[]?; .Key == "ManagedBy" and .Value == "gitops-course") and
    any(.TagSet[]?; .Key == "Project" and .Value == $project)
  ' <<<"$tags" >/dev/null || fail "state bucket ownership tag가 일치하지 않습니다: $bucket"

  location=$(aws s3api get-bucket-location --bucket "$bucket" --profile "$profile" --output json)
  if [[ "$region" == "us-east-1" ]]; then
    jq -e '.LocationConstraint == null' <<<"$location" >/dev/null || \
      fail "state bucket Region이 us-east-1이 아닙니다: $bucket"
  else
    jq -e --arg region "$region" '.LocationConstraint == $region' <<<"$location" >/dev/null || \
      fail "state bucket Region이 일치하지 않습니다: $bucket"
  fi

  versioning=$(aws s3api get-bucket-versioning --bucket "$bucket" --profile "$profile" --output json)
  jq -e '.Status == "Enabled"' <<<"$versioning" >/dev/null || fail "state bucket versioning이 Enabled가 아닙니다."

  encryption=$(aws s3api get-bucket-encryption --bucket "$bucket" --profile "$profile" --output json)
  jq -e 'any(.ServerSideEncryptionConfiguration.Rules[]?; .ApplyServerSideEncryptionByDefault.SSEAlgorithm == "AES256" or .ApplyServerSideEncryptionByDefault.SSEAlgorithm == "aws:kms")' \
    <<<"$encryption" >/dev/null || fail "state bucket 기본 암호화가 없습니다."

  public_block=$(aws s3api get-public-access-block --bucket "$bucket" --profile "$profile" --output json)
  jq -e '.PublicAccessBlockConfiguration | .BlockPublicAcls and .IgnorePublicAcls and .BlockPublicPolicy and .RestrictPublicBuckets' \
    <<<"$public_block" >/dev/null || fail "state bucket public access block 네 항목이 모두 true가 아닙니다."

  pass "Terraform state bucket 보안 상태가 유효합니다(bucket=$bucket)."
}

check_dns_delegation() {
  local profile=$1 hosted_zone_id=$2 root_domain=$3
  local route53_nameservers public_nameservers

  route53_nameservers=$(aws route53 get-hosted-zone \
    --id "$hosted_zone_id" --profile "$profile" --output json \
    | jq -r '.DelegationSet.NameServers[]' \
    | normalize_nameservers)
  public_nameservers=$(dig +short NS "$root_domain" | normalize_nameservers)

  [[ -n "$route53_nameservers" ]] || fail "Route 53 nameserver 응답이 비어 있습니다."
  [[ -n "$public_nameservers" ]] || fail "public DNS nameserver 응답이 비어 있습니다. registrar 위임을 확인하십시오."
  [[ "$route53_nameservers" == "$public_nameservers" ]] || \
    fail "Route 53 지정 nameserver와 public DNS 응답이 다릅니다."

  printf 'DNS_NAMESERVERS:\n%s\n' "$public_nameservers"
  pass "DNS delegation이 일치합니다(domain=$root_domain)."
}

find_github_oidc_provider() {
  local profile=$1 provider_arns provider_arn provider_json count=0 selected=""
  provider_arns=$(aws iam list-open-id-connect-providers --profile "$profile" --output json \
    | jq -r '.OpenIDConnectProviderList[].Arn')

  while IFS= read -r provider_arn; do
    [[ -n "$provider_arn" ]] || continue
    provider_json=$(aws iam get-open-id-connect-provider \
      --open-id-connect-provider-arn "$provider_arn" --profile "$profile" --output json)
    if [[ "$(jq -r '.Url' <<<"$provider_json")" == "token.actions.githubusercontent.com" ]]; then
      count=$((count + 1))
      selected=$provider_arn
      jq -e 'any(.ClientIDList[]?; . == "sts.amazonaws.com")' <<<"$provider_json" >/dev/null || \
        fail "GitHub OIDC provider에 sts.amazonaws.com audience가 없습니다."
    fi
  done <<<"$provider_arns"

  [[ "$count" -eq 1 ]] || fail "GitHub OIDC provider는 계정에 정확히 1개여야 합니다(found=$count)."
  printf 'GITHUB_OIDC_ARN=%s\n' "$selected"
  pass "account-wide GitHub OIDC provider가 유일하며 audience가 유효합니다."
}

check_immutable_subject() {
  local repository=$1 metadata customization owner name owner_id repository_id subject
  metadata=$(gh api -H "X-GitHub-Api-Version: $API_VERSION" "repos/$repository")
  customization=$(gh api -H "X-GitHub-Api-Version: $API_VERSION" \
    "repos/$repository/actions/oidc/customization/sub")
  jq -e '.use_immutable_subject == true' <<<"$customization" >/dev/null || \
    fail "$repository immutable OIDC subject가 활성화되지 않았습니다."

  owner=$(jq -r '.owner.login' <<<"$metadata")
  name=$(jq -r '.name' <<<"$metadata")
  owner_id=$(jq -r '.owner.id' <<<"$metadata")
  repository_id=$(jq -r '.id' <<<"$metadata")
  subject="repo:${owner}@${owner_id}/${name}@${repository_id}:ref:refs/heads/main"
  printf 'IMMUTABLE_MAIN_SUB[%s]=%s\n' "$repository" "$subject"
}

check_ruleset() {
  local repository=$1 rulesets ruleset_id detail
  rulesets=$(gh api -H "X-GitHub-Api-Version: $API_VERSION" "repos/$repository/rulesets")
  ruleset_id=$(jq -r '[.[] | select(.name == "main-protection" and .enforcement == "active" and .target == "branch")] | if length == 1 then .[0].id else empty end' \
    <<<"$rulesets")
  [[ -n "$ruleset_id" ]] || fail "$repository active main-protection Ruleset을 정확히 하나 찾지 못했습니다."

  detail=$(gh api -H "X-GitHub-Api-Version: $API_VERSION" "repos/$repository/rulesets/$ruleset_id")
  jq -e '
    (.bypass_actors | length) == 0 and
    any(.rules[]?; .type == "pull_request" and .parameters.require_code_owner_review == true) and
    any(.rules[]?; .type == "required_status_checks" and
      any(.parameters.required_status_checks[]?; .context == "validate"))
  ' <<<"$detail" >/dev/null || fail "$repository main-protection Ruleset 상세 조건이 일치하지 않습니다."

  pass "GitHub main-protection Ruleset이 유효합니다(repository=$repository, id=$ruleset_id)."
}

check_secret_json() {
  local secret_file=$1 secret_directory
  [[ -f "$secret_file" ]] || fail "secret JSON 파일을 찾을 수 없습니다: $secret_file"
  secret_directory=$(cd "$(dirname "$secret_file")" && pwd -P)
  if git -C "$secret_directory" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail "secret JSON은 Git worktree 밖에 두어야 합니다: $secret_file"
  fi
  jq -e '
    type == "object" and
    (keys | sort == ["API_KEY", "DB_HOST", "DB_PASSWORD"]) and
    all(.[]; type == "string" and length > 0)
  ' "$secret_file" >/dev/null || \
    fail "secret JSON은 API_KEY, DB_HOST, DB_PASSWORD의 비어 있지 않은 문자열만 포함해야 합니다."
  pass "secret JSON key 구조가 유효하며 값은 출력하지 않았습니다."
}

check_ch02() {
  for command in aws dig gh git jq awk sort tr; do
    require_command "$command"
  done
  for name in AWS_PROFILE AWS_REGION STATE_BUCKET_NAME LAB_PROJECT_NAME HOSTED_ZONE_ID ROOT_DOMAIN INFRA_GH_REPO APP_GH_REPO GITOPS_GH_REPO; do
    require_environment "$name"
  done

  check_state_bucket "$AWS_PROFILE" "$AWS_REGION" "$STATE_BUCKET_NAME" "$LAB_PROJECT_NAME"
  check_dns_delegation "$AWS_PROFILE" "$HOSTED_ZONE_ID" "$ROOT_DOMAIN"
  find_github_oidc_provider "$AWS_PROFILE"
  check_immutable_subject "$INFRA_GH_REPO"
  check_immutable_subject "$APP_GH_REPO"
  check_ruleset "$GITOPS_GH_REPO"
  if [[ -n "${SECRET_JSON_FILE:-}" ]]; then
    check_secret_json "$SECRET_JSON_FILE"
  fi
  pass "ch02 외부 상태와 보안 계약이 유효합니다."
}

check_workflow_run() {
  local chapter=$1 repository=${2:-} head_sha=${3:-} workflow=${4:-test.yml} event=${5:-push}
  [[ -n "$repository" && -n "$head_sha" ]] || \
    fail "사용법: bash scripts/course-check.sh $chapter <owner/repository> <commit-sha> [workflow] [event]" 64
  require_command gh
  require_command jq

  local attempts=${COURSE_CHECK_WAIT_ATTEMPTS:-30}
  local delay=${COURSE_CHECK_WAIT_SECONDS:-2}
  local attempt=0 runs run_id="" final
  while ((attempt < attempts)); do
    runs=$(gh run list --repo "$repository" --workflow "$workflow" --event "$event" \
      --limit 50 --json databaseId,headSha,status,conclusion,url)
    run_id=$(jq -r --arg sha "$head_sha" \
      '[.[] | select(.headSha == $sha)] | sort_by(.databaseId) | last | .databaseId // empty' \
      <<<"$runs")
    [[ -n "$run_id" ]] && break
    attempt=$((attempt + 1))
    ((attempt < attempts)) && sleep "$delay"
  done
  [[ -n "$run_id" ]] || fail "$repository에서 commit SHA $head_sha workflow run을 찾지 못했습니다."

  gh run watch "$run_id" --repo "$repository" --exit-status
  final=$(gh run view "$run_id" --repo "$repository" \
    --json databaseId,headSha,status,conclusion,url)
  jq -e --arg sha "$head_sha" '.headSha == $sha and .status == "completed" and .conclusion == "success"' \
    <<<"$final" >/dev/null || fail "선택한 workflow run이 요청 SHA의 success 상태가 아닙니다."
  jq '{databaseId, headSha, status, conclusion, url}' <<<"$final"
  pass "$chapter exact-SHA workflow가 성공했습니다(run_id=$run_id)."
}

cidr_range() {
  local cidr=$1 address prefix a b c d octet ip mask network broadcast
  [[ "$cidr" == */* ]] || return 2
  address=${cidr%/*}
  prefix=${cidr#*/}
  [[ "$prefix" =~ ^[0-9]+$ ]] && ((prefix >= 0 && prefix <= 32)) || return 2
  IFS=. read -r a b c d <<<"$address"
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]+$ ]] && ((10#$octet >= 0 && 10#$octet <= 255)) || return 2
  done
  ip=$(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))
  if ((prefix == 0)); then
    mask=0
  else
    mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
  fi
  network=$((ip & mask))
  broadcast=$((network | (0xFFFFFFFF ^ mask)))
  printf '%s %s\n' "$network" "$broadcast"
}

check_ch08() {
  local first=${1:-} second=${2:-} first_start first_end second_start second_end
  [[ -n "$first" && -n "$second" ]] || \
    fail "사용법: bash scripts/course-check.sh ch08 <first-ipv4-cidr> <second-ipv4-cidr>" 64
  read -r first_start first_end < <(cidr_range "$first") || fail "유효하지 않은 IPv4 CIDR입니다: $first" 64
  read -r second_start second_end < <(cidr_range "$second") || fail "유효하지 않은 IPv4 CIDR입니다: $second" 64
  printf 'CIDR_RANGE: %s start=%s end=%s\n' "$first" "$first_start" "$first_end"
  printf 'CIDR_RANGE: %s start=%s end=%s\n' "$second" "$second_start" "$second_end"
  if ((first_start <= second_end && second_start <= first_end)); then
    fail "CIDR가 겹칩니다: $first, $second" 2
  fi
  pass "ch08 CIDR가 서로 겹치지 않습니다."
}

check_ch10() {
  local context=${1:-course-dev} namespace=${2:-dev}
  require_command kubectl
  require_command jq

  local nodes application external_secret deployment
  nodes=$(kubectl --context "$context" get nodes -o json)
  jq -e '(.items | length) > 0 and all(.items[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))' \
    <<<"$nodes" >/dev/null || fail "Ready 상태가 아닌 Dev node가 있습니다."

  application=$(kubectl --context "$context" -n argocd get application sample-app-dev -o json)
  jq -e '.status.sync.status == "Synced" and .status.health.status == "Healthy"' \
    <<<"$application" >/dev/null || fail "sample-app-dev Application이 Synced/Healthy가 아닙니다."

  external_secret=$(kubectl --context "$context" -n "$namespace" get externalsecret sample-app -o json)
  jq -e 'any(.status.conditions[]?; .type == "Ready" and .status == "True")' \
    <<<"$external_secret" >/dev/null || fail "sample-app ExternalSecret이 Ready가 아닙니다."

  deployment=$(kubectl --context "$context" -n "$namespace" get deployment sample-app -o json)
  jq -e '.status.availableReplicas > 0 and .status.availableReplicas == .status.replicas' \
    <<<"$deployment" >/dev/null || fail "sample-app Deployment replica가 모두 Available이 아닙니다."

  pass "ch10 Dev 핵심 runtime 상태가 Ready/Synced/Healthy입니다."
}

usage() {
  printf '%s\n' \
    'Usage: bash scripts/course-check.sh <chapter> [arguments]' \
    '  ch01 <three-repositories-root>' \
    '  ch02' \
    '  ch03|ch11|ch12|ch13 <owner/repository> <commit-sha> [workflow] [event]' \
    '  ch08 <first-ipv4-cidr> <second-ipv4-cidr>' \
    '  ch10 [kubectl-context] [namespace]'
}

chapter=${1:-}
[[ -n "$chapter" ]] || {
  usage >&2
  exit 64
}
shift

case "$chapter" in
  ch01) check_ch01 "$@" ;;
  ch02) check_ch02 "$@" ;;
  ch03) check_workflow_run ch03 "$@" ;;
  ch08) check_ch08 "$@" ;;
  ch10) check_ch10 "$@" ;;
  ch11) check_workflow_run ch11 "$@" ;;
  ch12) check_workflow_run ch12 "$@" ;;
  ch13) check_workflow_run ch13 "$@" ;;
  *)
    usage >&2
    fail "지원하지 않는 Chapter입니다: $chapter" 64
    ;;
esac
