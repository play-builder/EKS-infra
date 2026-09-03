#!/usr/bin/env bash
set -Eeuo pipefail

API_VERSION="2026-03-10"
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then
  [[ -d "$COURSE_CHECK_BIN_DIR" ]] || {
    printf 'ERROR: COURSE_CHECK_BIN_DIR가 directory가 아닙니다: %s\n' "$COURSE_CHECK_BIN_DIR" >&2
    exit 64
  }
  PATH="$COURSE_CHECK_BIN_DIR:$PATH"
fi

fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit "${2:-1}"
}

pass() {
  printf 'DETAIL: %s\n' "$1"
}

emit_pass() {
  local grade=$1 message=$2
  if [[ "$grade" == "STATIC" && -n "${COURSE_CHECK_BIN_DIR:-}" && "$message" != SIMULATED_CLOUD_CONTRACT* ]]; then
    message="SIMULATED_CLOUD_CONTRACT $message"
  fi
  printf 'PASS: [%s] %s\n' "$grade" "$message"
}

validate_region() {
  local region=${1:-}
  [[ "$region" == "ap-northeast-2" || "$region" == "us-east-1" ]] || \
    fail "AWS_REGION은 ap-northeast-2 또는 us-east-1이어야 합니다: ${region:-<empty>}" 64
}

runtime_grade() {
  if [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then
    printf 'STATIC'
  else
    printf 'CLOUD_RUNTIME'
  fi
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
  validate_region "$AWS_REGION"

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
  local chapter=$1 repository=${2:-} head_sha=${3:-} workflow_name=${4:-CI} event=${5:-push}
  [[ -n "$repository" && -n "$head_sha" ]] || \
    fail "사용법: bash scripts/course-check.sh $chapter <owner/repository> <commit-sha> [workflow] [event]" 64
  require_command gh
  require_command jq

  local before_id=${6:-0}
  [[ "$before_id" =~ ^[0-9]+$ ]] || fail "before_id는 0 이상의 workflow database ID여야 합니다: $before_id" 64

  local attempts=${COURSE_CHECK_WAIT_ATTEMPTS:-30}
  local delay=${COURSE_CHECK_WAIT_SECONDS:-2}
  local attempt=0 runs run_id="" final candidates candidate_count
  while ((attempt < attempts)); do
    runs=$(gh run list --repo "$repository" --workflow "$workflow_name" --event "$event" \
      --limit 50 --json databaseId,headSha,workflowName,event,status,conclusion,url)
    candidates=$(jq -c --arg sha "$head_sha" --arg workflow "$workflow_name" \
      --arg event "$event" --argjson before "$before_id" \
      '[.[] | select(.headSha == $sha and .workflowName == $workflow and .event == $event and .databaseId > $before)]' \
      <<<"$runs")
    candidate_count=$(jq -r 'length' <<<"$candidates")
    ((candidate_count <= 1)) || fail "AMBIGUOUS_RUN: exact workflow 후보가 ${candidate_count}개입니다."
    run_id=$(jq -r 'if length == 1 then .[0].databaseId else empty end' <<<"$candidates")
    [[ -n "$run_id" ]] && break
    attempt=$((attempt + 1))
    ((attempt < attempts)) && sleep "$delay"
  done
  [[ -n "$run_id" ]] || fail "EXACT_RUN_NOT_FOUND: ${repository}에서 지정한 SHA/workflow/event의 run을 찾지 못했습니다."

  gh run watch "$run_id" --repo "$repository" --exit-status
  final=$(gh run view "$run_id" --repo "$repository" \
    --json databaseId,headSha,workflowName,event,status,conclusion,url)
  jq -e --arg sha "$head_sha" --arg workflow "$workflow_name" --arg event "$event" '
    .headSha == $sha and .workflowName == $workflow and .event == $event and
    .status == "completed" and .conclusion == "success"
  ' \
    <<<"$final" >/dev/null || fail "선택한 workflow run이 요청 SHA의 success 상태가 아닙니다."
  jq '{databaseId, headSha, status, conclusion, url}' <<<"$final"
  pass "$chapter exact-SHA workflow가 성공했습니다(run_id=$run_id)."
}

check_ch05() {
  local repository_name=${1:-} digest=${2:-}
  [[ -n "$repository_name" && -n "$digest" ]] || \
    fail "사용법: bash scripts/course-check.sh ch05 <ecr-repository-name> <sha256-digest>" 64
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "유효하지 않은 image digest입니다: $digest" 64
  require_command aws
  require_command jq
  require_environment AWS_PROFILE
  require_environment AWS_REGION
  validate_region "$AWS_REGION"

  local response platforms
  response=$(aws ecr batch-get-image \
    --repository-name "$repository_name" \
    --image-ids "imageDigest=$digest" \
    --accepted-media-types \
      application/vnd.oci.image.index.v1+json \
      application/vnd.docker.distribution.manifest.list.v2+json \
    --region "$AWS_REGION" \
    --profile "$AWS_PROFILE" \
    --output json)

  jq -e --arg digest "$digest" '
    (.failures | length) == 0 and
    (.images | length) == 1 and
    .images[0].imageId.imageDigest == $digest
  ' <<<"$response" >/dev/null || fail "요청한 digest의 ECR image index를 찾지 못했습니다."

  platforms=$(jq -r '
    .images[0].imageManifest
    | fromjson
    | [.manifests[]?.platform | select(.os == "linux") | .architecture]
    | unique
    | sort
    | join(",")
  ' <<<"$response")
  [[ "$platforms" == "amd64,arm64" ]] || \
    fail "ECR index에 linux/amd64와 linux/arm64가 모두 없습니다(found=$platforms)."

  printf 'ECR_INDEX: repository=%s digest=%s platforms=%s\n' "$repository_name" "$digest" "$platforms"
  pass "ch05 ECR multi-architecture image index가 유효합니다."
}

check_ch06() {
  if [[ "${1:-}" == "--lifecycle-preview" ]]; then
    shift
    COURSE_CHECK_DETAIL_ONLY=true bash "$SCRIPT_DIR/ecr-lifecycle-preview.sh" "$@"
  else
    check_ch05 "$@"
  fi
}

check_contract_only() {
  local chapter=$1 mode=${2:-}
  [[ "$mode" == "--contract-only" ]] || \
    fail "$chapter runtime checker에 필요한 인수가 없습니다. --contract-only는 offline contract test 전용입니다." 64
  [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]] || \
    fail "--contract-only는 COURSE_CHECK_BIN_DIR가 있는 offline test에서만 사용할 수 있습니다." 64
  [[ -n "${AWS_REGION:-}" ]] && validate_region "$AWS_REGION"
  printf 'DETAIL: %s public command shape is registered.\n' "$chapter"
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

check_stateful() {
  local context=${1:-} namespace=${2:-} base_url=${3:-}
  [[ -n "$context" && -n "$namespace" && -n "$base_url" ]] || \
    fail "사용법: bash scripts/course-check.sh stateful <kubectl-context> <namespace> <base-url>" 64
  base_url=${base_url%/}
  for command in kubectl jq curl; do
    require_command "$command"
  done

  local storage_class stateful_set claims migration_job application_pods products inventory order
  storage_class=$(kubectl --context "$context" get storageclass/course-gp3 -o json)
  jq -e '
    .provisioner == "ebs.csi.aws.com" and
    .reclaimPolicy == "Delete" and
    .volumeBindingMode == "WaitForFirstConsumer" and
    .allowVolumeExpansion == true and
    .parameters.type == "gp3" and
    .parameters.encrypted == "true"
  ' <<<"$storage_class" >/dev/null || fail "course-gp3 StorageClass 계약이 일치하지 않습니다."

  stateful_set=$(kubectl --context "$context" -n "$namespace" get statefulset sample-app-postgresql -o json)
  jq -e '.spec.replicas == 1 and .status.readyReplicas == 1 and .status.currentRevision == .status.updateRevision' \
    <<<"$stateful_set" >/dev/null || fail "PostgreSQL StatefulSet이 Ready가 아닙니다."

  claims=$(kubectl --context "$context" -n "$namespace" get pvc \
    -l app.kubernetes.io/component=database -o json)
  jq -e '
    (.items | length) == 1 and
    all(.items[]; .status.phase == "Bound" and .spec.storageClassName == "course-gp3")
  ' <<<"$claims" >/dev/null || fail "PostgreSQL PVC가 course-gp3에 Bound되지 않았습니다."

  migration_job=$(kubectl --context "$context" -n "$namespace" get job sample-app-migration -o json)
  jq -e '.status.succeeded >= 1 and (.status.failed // 0) == 0' \
    <<<"$migration_job" >/dev/null || fail "schema migration Job이 성공하지 않았습니다."

  application_pods=$(kubectl --context "$context" -n "$namespace" get pods \
    -l app.kubernetes.io/name=sample-app -o json)
  jq -e '
    (.items | length) > 0 and
    all(.items[]; any(.status.conditions[]?; .type == "Ready" and .status == "True"))
  ' <<<"$application_pods" >/dev/null || fail "Mini Commerce application Pod가 모두 Ready가 아닙니다."

  products=$(curl --fail --silent --show-error --max-time 5 "$base_url/products")
  jq -e '.products | type == "array" and length >= 4' <<<"$products" >/dev/null || \
    fail "상품 목록 API가 mock 상품을 반환하지 않습니다."
  inventory=$(curl --fail --silent --show-error --max-time 5 "$base_url/products/1/inventory")
  jq -e '.productId == 1 and (.availableQuantity | type == "number")' <<<"$inventory" >/dev/null || \
    fail "재고 API 응답이 유효하지 않습니다."
  order=$(curl --fail --silent --show-error --max-time 5 \
    --request POST "$base_url/orders" \
    --header 'Content-Type: application/json' \
    --header "Idempotency-Key: course-check-$namespace" \
    --data '{"items":[{"productId":4,"quantity":1}]}')
  jq -e '.order.status == "CONFIRMED" and .order.totalCents == 32900 and (.order.id | type == "number")' \
    <<<"$order" >/dev/null || fail "멱등 주문 생성 API 응답이 유효하지 않습니다."

  jq '{productCount: (.products | length), firstSku: .products[0].sku}' <<<"$products"
  jq '{productId, availableQuantity}' <<<"$inventory"
  jq '{orderId: .order.id, status: .order.status, totalCents: .order.totalCents}' <<<"$order"
  pass "Stateful Mini Commerce storage, migration, Pod, 상품·재고·주문 API가 유효합니다."
}

validate_dev_deployment_evidence() {
  local file=${1:-} now=${2:-$(date -u +%Y-%m-%dT%H:%M:%SZ)} expected_grade=${3:-CLOUD_RUNTIME}
  [[ -f "$file" ]] || fail "Ch15 evidence file을 찾을 수 없습니다: $file" 66
  jq -e --arg now "$now" --arg grade "$expected_grade" '
    (keys | sort) == (["clusterArn","evidenceGrade","gitopsRevision","image","observedAt","region","schemaVersion","source","status"] | sort) and
    .schemaVersion == "course.dev-deployment/v1" and
    .evidenceGrade == $grade and
    .status == {"sync":"Synced","health":"Healthy"} and
    (.source | keys | sort) == ["repository","sha"] and
    (.source.repository | type == "string" and length > 0) and
    (.source.sha | test("^[0-9a-f]{40}$")) and
    (.image | keys | sort) == ["indexDigest","repository"] and
    (.image.repository | type == "string" and length > 0) and
    (.image.indexDigest | test("^sha256:[0-9a-f]{64}$")) and
    (.gitopsRevision | test("^[0-9a-f]{40}$")) and
    (.clusterArn | test("^arn:aws:eks:(ap-northeast-2|us-east-1):[0-9]{12}:cluster/")) and
    (.region == "ap-northeast-2" or .region == "us-east-1") and
    (.clusterArn | split(":")[3]) == .region and
    ((.observedAt | fromdateiso8601) <= ($now | fromdateiso8601))
  ' "$file" >/dev/null || fail "Ch15 evidence schema, grade, identity, or Synced/Healthy status is invalid."
}

validate_dev_slo_evidence() {
  local deployment=${1:-} slo=${2:-} now=${3:-$(date -u +%Y-%m-%dT%H:%M:%SZ)} expected_grade=${4:-CLOUD_RUNTIME}
  validate_dev_deployment_evidence "$deployment" "$now" "$expected_grade"
  [[ -f "$slo" ]] || fail "Ch16 evidence file을 찾을 수 없습니다: $slo" 66
  jq -e --arg now "$now" --arg grade "$expected_grade" --slurpfile deployment "$deployment" '
    (keys | sort) == (["clusterArn","evidenceGrade","evidenceId","expiresAt","gitopsRevision","image","observedAt","region","schemaVersion","source","status"] | sort) and
    .schemaVersion == "course.dev-slo/v1" and
    .evidenceGrade == $grade and
    .status == "PASS" and
    (.source | keys | sort) == ["repository","sha"] and
    (.image | keys | sort) == ["indexDigest","repository"] and
    (.evidenceId | test("^sha256:[0-9a-f]{64}$")) and
    .source == $deployment[0].source and
    .image == $deployment[0].image and
    .gitopsRevision == $deployment[0].gitopsRevision and
    .clusterArn == $deployment[0].clusterArn and
    .region == $deployment[0].region and
    ((.observedAt | fromdateiso8601) <= ($now | fromdateiso8601)) and
    ((.observedAt | fromdateiso8601) < (.expiresAt | fromdateiso8601)) and
    (($now | fromdateiso8601) < (.expiresAt | fromdateiso8601))
  ' "$slo" >/dev/null || fail "Ch16 evidence schema, grade, PASS status, identity, or validity interval is invalid."
}

validate_evidence_output_path() {
  local output=${1:-}
  [[ -n "$output" ]] || fail "--output path가 필요합니다." 64
  case "$output" in
    argocd-gitops/evidence/dev/deployment.json|argocd-gitops/evidence/dev/slo.json|*/argocd-gitops/evidence/dev/deployment.json|*/argocd-gitops/evidence/dev/slo.json)
      fail "EKS-infra checker는 GitOps handoff 경로를 직접 쓰지 않습니다: $output" 64
      ;;
  esac
  [[ -d "$(dirname -- "$output")" ]] || fail "output directory가 없습니다: $(dirname -- "$output")" 66
}

write_json_atomic() {
  local output=$1 payload=$2 tmp
  validate_evidence_output_path "$output"
  tmp=$(mktemp "${output}.tmp.XXXXXX")
  trap 'rm -f -- "$tmp"' RETURN
  printf '%s\n' "$payload" >"$tmp"
  jq -e . "$tmp" >/dev/null || fail "생성된 evidence JSON이 유효하지 않습니다."
  mv -- "$tmp" "$output"
  trap - RETURN
}

one_hour_after() {
  local now=$1
  date -u -j -v+1H -f '%Y-%m-%dT%H:%M:%SZ' "$now" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
    date -u -d "$now + 1 hour" '+%Y-%m-%dT%H:%M:%SZ'
}

check_ch12() {
  if [[ "${1:-}" == "--contract-only" ]]; then
    check_contract_only ch12 "$@"
    return
  fi
  local context=${1:-} namespace=${2:-} external_secret=${3:-} rollout=${4:-}
  local runtime_secret=${5:-} expected_version=${6:-} previous_pod_uid=${7:-}
  [[ $# -eq 7 ]] || fail "사용법: ch12 <context> <namespace> <externalsecret> <rollout> <runtime-secret-id> <version-id> <previous-pod-uid>" 64
  [[ "$runtime_secret" == */sample-app-runtime ]] || fail "Ch12 reload target은 sample-app-runtime secret이어야 합니다." 64
  for command in aws kubectl jq; do require_command "$command"; done
  for name in AWS_PROFILE AWS_REGION; do require_environment "$name"; done
  validate_region "$AWS_REGION"

  local secret external rollout_json pods current_hash
  secret=$(aws secretsmanager describe-secret --secret-id "$runtime_secret" --region "$AWS_REGION" --profile "$AWS_PROFILE" --output json)
  jq -e --arg version "$expected_version" '.VersionIdsToStages[$version] | index("AWSCURRENT") != null' \
    <<<"$secret" >/dev/null || fail "expected runtime secret VersionId가 AWSCURRENT가 아닙니다."
  external=$(kubectl --context "$context" -n "$namespace" get externalsecret "$external_secret" -o json)
  jq -e --arg version "$expected_version" '
    .metadata.generation as $generation |
    any(.status.conditions[]?; .type == "Ready" and .status == "True" and ((.observedGeneration // $generation) == $generation)) and
    (.status.syncedResourceVersion == $version)
  ' <<<"$external" >/dev/null || fail "ExternalSecret이 current generation/VersionId를 Ready로 동기화하지 않았습니다."
  rollout_json=$(kubectl --context "$context" -n "$namespace" get rollout "$rollout" -o json)
  current_hash=$(jq -r '.status.currentPodHash // empty' <<<"$rollout_json")
  [[ -n "$current_hash" ]] || fail "Rollout currentPodHash가 없습니다."
  pods=$(kubectl --context "$context" -n "$namespace" get pods -l "rollouts-pod-template-hash=$current_hash" -o json)
  jq -e --arg previous "$previous_pod_uid" '
    (.items | length) > 0 and all(.items[]; any(.status.conditions[]?; .type == "Ready" and .status == "True")) and
    any(.items[]; .metadata.uid != $previous)
  ' <<<"$pods" >/dev/null || fail "runtime secret 변경 후 새 Ready Pod UID를 확인하지 못했습니다."
  printf 'SECRET_RELOAD: version=%s currentPodHash=%s\n' "$expected_version" "$current_hash"
}

check_ch15() {
  if [[ "${1:-}" == "--contract-only" ]]; then
    check_contract_only ch15 "$@"
    return
  fi
  if [[ "${1:-}" == "--validate-evidence" ]]; then
    [[ $# -eq 3 ]] || fail "사용법: ch15 --validate-evidence <file> <now>" 64
    validate_dev_deployment_evidence "$2" "$3" CLOUD_RUNTIME
    return
  fi
  [[ $# -eq 12 && "${11}" == "--output" ]] || fail "사용법: ch15 <context> <app-namespace> <application> <source-repository> <source-sha> <image-repository> <image-digest> <gitops-revision> <cluster-arn> <region> --output <path>" 64
  local context=$1 namespace=$2 application=$3 source_repository=$4 source_sha=$5 image_repository=$6
  local image_digest=$7 gitops_revision=$8 cluster_arn=$9 region=${10} output=${12}
  validate_region "$region"
  [[ "$source_sha" =~ ^[0-9a-f]{40}$ && "$gitops_revision" =~ ^[0-9a-f]{40}$ ]] || fail "source와 GitOps revision은 40-char SHA여야 합니다." 64
  [[ "$image_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "image digest가 유효하지 않습니다." 64
  for command in aws kubectl jq; do require_command "$command"; done
  require_environment AWS_PROFILE
  validate_evidence_output_path "$output"

  local app cluster cluster_name now grade payload
  app=$(kubectl --context "$context" -n argocd get application "$application" -o json)
  jq -e --arg revision "$gitops_revision" '
    .status.sync.status == "Synced" and .status.health.status == "Healthy" and
    .status.sync.revision == $revision
  ' <<<"$app" >/dev/null || fail "Dev Argo Application이 요청 GitOps revision에서 Synced/Healthy가 아닙니다."
  cluster_name=${cluster_arn##*/}
  cluster=$(aws eks describe-cluster --name "$cluster_name" --region "$region" --profile "$AWS_PROFILE" --output json)
  jq -e --arg arn "$cluster_arn" --arg region "$region" '.cluster.arn == $arn and .cluster.status == "ACTIVE" and .cluster.arn | contains(":"+$region+":")' \
    <<<"$cluster" >/dev/null || fail "Dev EKS cluster ARN/Region/ACTIVE 상태가 일치하지 않습니다."
  now=${COURSE_CHECK_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  grade=$(runtime_grade)
  payload=$(jq -n --arg grade "$grade" --arg source_repository "$source_repository" --arg source_sha "$source_sha" \
    --arg image_repository "$image_repository" --arg image_digest "$image_digest" --arg gitops_revision "$gitops_revision" \
    --arg cluster_arn "$cluster_arn" --arg region "$region" --arg now "$now" '
      {schemaVersion:"course.dev-deployment/v1",evidenceGrade:$grade,status:{sync:"Synced",health:"Healthy"},
       source:{repository:$source_repository,sha:$source_sha},image:{repository:$image_repository,indexDigest:$image_digest},
       gitopsRevision:$gitops_revision,clusterArn:$cluster_arn,region:$region,observedAt:$now}')
  write_json_atomic "$output" "$payload"
  validate_dev_deployment_evidence "$output" "$now" "$grade"
  printf 'DEV_DEPLOYMENT_EVIDENCE: %s\n' "$output"
}

check_ch16() {
  if [[ "${1:-}" == "--contract-only" ]]; then
    check_contract_only ch16 "$@"
    return
  fi
  if [[ "${1:-}" == "--validate-evidence" ]]; then
    [[ $# -eq 4 ]] || fail "사용법: ch16 --validate-evidence <deployment> <slo> <now>" 64
    validate_dev_slo_evidence "$2" "$3" "$4" CLOUD_RUNTIME
    return
  fi
  [[ $# -eq 9 && "${8}" == "--output" ]] || fail "사용법: ch16 <deployment-evidence> <context> <k6-namespace> <testrun> <amp-workspace-id> <sns-topic-arn> <region> --output <path>" 64
  local deployment=$1 context=$2 namespace=$3 testrun=$4 workspace_id=$5 topic_arn=$6 region=$7 output=$9
  for command in aws kubectl jq; do require_command "$command"; done
  require_environment AWS_PROFILE
  require_environment ALERT_DELIVERY_EVIDENCE
  validate_region "$region"
  validate_evidence_output_path "$output"
  local grade now expected_grade operator crd run workspace workspace_arn workspace_account rules rule_text alertmanager alertmanager_text topic subscriptions query delivery expires evidence_id payload
  grade=$(runtime_grade)
  expected_grade=$grade
  validate_dev_deployment_evidence "$deployment" "${COURSE_CHECK_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" "$expected_grade"
  [[ "$(jq -r '.region' "$deployment")" == "$region" ]] || fail "Ch15/Ch16 Region identity가 다릅니다."

  operator=$(kubectl --context "$context" -n "$namespace" get deployment k6-operator-controller-manager -o json)
  jq -e '.status.availableReplicas >= 1 and .status.availableReplicas == .status.replicas' <<<"$operator" >/dev/null || fail "k6 operator Deployment가 Available이 아닙니다."
  crd=$(kubectl --context "$context" get crd testruns.k6.io -o json)
  jq -e 'any(.status.conditions[]?; .type == "Established" and .status == "True")' <<<"$crd" >/dev/null || fail "k6 TestRun CRD가 Established가 아닙니다."
  run=$(kubectl --context "$context" -n "$namespace" get testrun "$testrun" -o json)
  jq -e '
    .status.stage == "finished" and
    .metadata.annotations["course.platform/max-duration"] != null and
    .metadata.annotations["course.platform/max-rate"] != null and
    .metadata.annotations["course.platform/cost-boundary"] == "existing-eks-compute"
  ' <<<"$run" >/dev/null || fail "k6 run이 finished가 아니거나 duration/rate/cost boundary metadata가 없습니다."

  workspace=$(aws amp describe-workspace --workspace-id "$workspace_id" --region "$region" --profile "$AWS_PROFILE" --output json)
  jq -e --arg region "$region" --arg workspace_id "$workspace_id" '
    .workspace.status.statusCode == "ACTIVE" and
    .workspace.workspaceId == $workspace_id and
    (.workspace.prometheusEndpoint | contains("." + $region + ".")) and
    (.workspace.arn | test("^arn:aws:aps:" + $region + ":[0-9]{12}:workspace/" + $workspace_id + "$"))
  ' <<<"$workspace" >/dev/null || fail "AMP workspace ARN/endpoint/status/Region이 유효하지 않습니다."
  workspace_arn=$(jq -r '.workspace.arn' <<<"$workspace")
  workspace_account=$(jq -r '.workspace.arn | split(":")[4]' <<<"$workspace")
  rules=$(aws amp get-rule-groups-namespace --workspace-id "$workspace_id" --name course-release-slo --region "$region" --profile "$AWS_PROFILE" --output json)
  rule_text=$(jq -r '.data | @base64d' <<<"$rules")
  [[ "$rule_text" == *"course:http_success_ratio:5m"* && "$rule_text" == *"CourseDeadman"* ]] || fail "AMP recording rule/deadman alert가 없습니다."
  alertmanager=$(aws amp get-alert-manager-definition --workspace-id "$workspace_id" --region "$region" --profile "$AWS_PROFILE" --output json)
  jq -e '.status.statusCode == "ACTIVE" and (.data | length > 0)' <<<"$alertmanager" >/dev/null || fail "AMP Alertmanager definition이 ACTIVE가 아닙니다."
  alertmanager_text=$(jq -r '.data | @base64d' <<<"$alertmanager")
  [[ "$alertmanager_text" == *"sigv4"* && "$alertmanager_text" == *"region: $region"* && "$alertmanager_text" == *"$topic_arn"* ]] || fail "Alertmanager SNS topic/SigV4 Region 설정이 일치하지 않습니다."
  topic=$(aws sns get-topic-attributes --topic-arn "$topic_arn" --region "$region" --profile "$AWS_PROFILE" --output json)
  jq -e --arg topic "$topic_arn" --arg workspace "$workspace_arn" --arg account "$workspace_account" '
    .Attributes.TopicArn == $topic and
    (.Attributes.Policy | fromjson | any(.Statement[]?;
      .Principal.Service == "aps.amazonaws.com" and .Action == "sns:Publish" and
      .Resource == $topic and
      .Condition.ArnEquals["AWS:SourceArn"] == $workspace and
      .Condition.StringEquals["AWS:SourceAccount"] == $account))
  ' <<<"$topic" >/dev/null || fail "SNS topic 또는 exact AMP workspace/account-scoped delivery policy가 유효하지 않습니다."
  subscriptions=$(aws sns list-subscriptions-by-topic --topic-arn "$topic_arn" --region "$region" --profile "$AWS_PROFILE" --output json)
  jq -e 'any(.Subscriptions[]?; .SubscriptionArn != "PendingConfirmation" and (.SubscriptionArn | length > 0))' \
    <<<"$subscriptions" >/dev/null || fail "SNS subscription이 confirmed 상태가 아닙니다."
  query=$(aws amp query-metrics --workspace-id "$workspace_id" --query-string 'course:http_success_ratio:5m' --region "$region" --profile "$AWS_PROFILE" --output json)
  jq -e 'any(.data.result[]?; ((.value[1] | tonumber) >= 0.99))' <<<"$query" >/dev/null || fail "Dev SLO success ratio가 0.99 미만입니다."
  delivery=$(cat "$ALERT_DELIVERY_EVIDENCE")
  jq -e --arg topic "$topic_arn" '
    (keys | sort) == (["evidenceGrade","firing","observedAt","resolved","schemaVersion","topicArn"] | sort) and
    .schemaVersion == "course.alert-delivery/v1" and .evidenceGrade == "CLOUD_RUNTIME" and
    .topicArn == $topic and .firing.delivered == true and .resolved.delivered == true
  ' <<<"$delivery" >/dev/null || fail "Firing/Resolved SNS delivery evidence가 모두 필요합니다."

  now=${COURSE_CHECK_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  expires=$(one_hour_after "$now")
  evidence_id="sha256:$(printf '%s\n%s\n%s\n' "$(sha256sum "$deployment" 2>/dev/null | awk '{print $1}' || shasum -a 256 "$deployment" | awk '{print $1}')" "$workspace_id" "$now" | { if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi; } | awk '{print $1}')"
  payload=$(jq -n --slurpfile deployment "$deployment" --arg grade "$grade" --arg evidence_id "$evidence_id" --arg now "$now" --arg expires "$expires" '
    $deployment[0] as $d |
    {schemaVersion:"course.dev-slo/v1",evidenceGrade:$grade,status:"PASS",source:$d.source,image:$d.image,
     gitopsRevision:$d.gitopsRevision,clusterArn:$d.clusterArn,region:$d.region,evidenceId:$evidence_id,observedAt:$now,expiresAt:$expires}')
  write_json_atomic "$output" "$payload"
  validate_dev_slo_evidence "$deployment" "$output" "$now" "$grade"
  printf 'DEV_SLO_EVIDENCE: %s\n' "$output"
}

usage() {
  printf '%s\n' \
    'Usage: bash scripts/course-check.sh <chapter> [arguments]' \
    '  ch01 <three-repositories-root>' \
    '  ch02' \
    '  ch05 <owner/repository> <commit-sha> <workflow-name> <event> [before-id]' \
    '  ch06 <ecr-repository-name> <sha256-digest>' \
    '  ch12 <context> <namespace> <externalsecret> <rollout> <runtime-secret-id> <version-id> <previous-pod-uid>' \
    '  ch15 <context> <namespace> <application> <source-repository> <source-sha> <image-repository> <image-digest> <gitops-revision> <cluster-arn> <region> --output <path>' \
    '  ch16 <ch15-evidence> <context> <k6-namespace> <testrun> <amp-workspace-id> <sns-topic-arn> <region> --output <path>' \
    '  ch04|ch07..ch26 --contract-only (offline contract tests only; implemented chapters also accept it)' \
    '  ch10 [kubectl-context] [namespace]' \
    '  stateful <kubectl-context> <namespace> <base-url>'
}

chapter=${1:-}
[[ -n "$chapter" ]] || {
  usage >&2
  exit 64
}
shift

case "$chapter" in
  ch01) check_ch01 "$@"; emit_pass STATIC "ch01 repository baseline이 유효합니다." ;;
  ch02) check_ch02 "$@"; emit_pass "$(runtime_grade)" "ch02 state, identity, governance 계약이 유효합니다." ;;
  ch05) check_workflow_run ch05 "$@"; emit_pass "$(runtime_grade)" "ch05 exact workflow 실행이 유효합니다." ;;
  ch06) check_ch06 "$@"; emit_pass "$(runtime_grade)" "ch06 image index와 rollback retention이 유효합니다." ;;
  ch12) check_ch12 "$@"; emit_pass "$(runtime_grade)" "ch12 runtime secret freshness와 Pod reload가 유효합니다." ;;
  ch14)
    if [[ "${1:-}" == "--contract-only" ]]; then
      check_contract_only "$chapter" "$@"
    else
      COURSE_CHECK_DETAIL_ONLY=true bash "$SCRIPT_DIR/network-policy-runtime.sh" "$@"
    fi
    emit_pass "$(runtime_grade)" "ch14 VPC CNI NetworkPolicy runtime 계약이 유효합니다."
    ;;
  ch15) check_ch15 "$@"; emit_pass "$(runtime_grade)" "ch15 Dev deployment evidence가 유효합니다." ;;
  ch16) check_ch16 "$@"; emit_pass "$(runtime_grade)" "ch16 Dev SLO, k6, AMP, SNS evidence가 유효합니다." ;;
  ch03|ch04|ch07|ch08|ch09|ch10|ch11|ch13|ch17|ch18|ch19|ch20|ch21|ch22|ch23|ch24|ch25|ch26)
    check_contract_only "$chapter" "$@"
    emit_pass STATIC "SIMULATED_CLOUD_CONTRACT $chapter dispatcher가 등록됐습니다."
    ;;
  stateful) check_stateful "$@"; emit_pass "$(runtime_grade)" "Stateful Mini Commerce runtime 계약이 유효합니다." ;;
  *)
    usage >&2
    fail "지원하지 않는 Chapter입니다: $chapter" 64
    ;;
esac
