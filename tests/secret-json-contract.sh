#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin" "$tmp_dir/secrets"

cat >"$tmp_dir/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  *"route53 get-hosted-zone"*) echo '{"DelegationSet":{"NameServers":["ns-1.example.invalid.","ns-2.example.invalid."]}}' ;;
  *"s3api get-bucket-tagging"*)
    echo '{"TagSet":[{"Key":"ManagedBy","Value":"gitops-course"},{"Key":"Project","Value":"course"}]}' ;;
  *"s3api get-bucket-location"*) echo '{"LocationConstraint":"ap-northeast-2"}' ;;
  *"s3api get-bucket-versioning"*) echo '{"Status":"Enabled"}' ;;
  *"s3api get-bucket-encryption"*) echo '{"ServerSideEncryptionConfiguration":{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}}' ;;
  *"s3api get-public-access-block"*) echo '{"PublicAccessBlockConfiguration":{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}}' ;;
  *"iam list-open-id-connect-providers"*) echo '{"OpenIDConnectProviderList":[{"Arn":"arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"}]}' ;;
  *"iam get-open-id-connect-provider"*) echo '{"Url":"token.actions.githubusercontent.com","ClientIDList":["sts.amazonaws.com"]}' ;;
  *) printf 'unexpected aws invocation: %s\n' "$*" >&2; exit 97 ;;
esac
EOF

cat >"$tmp_dir/bin/dig" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
echo 'ns-1.example.invalid.'
echo 'ns-2.example.invalid.'
EOF

cat >"$tmp_dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  *"repos/owner/infra/actions/oidc/customization/sub"*) echo '{"use_immutable_subject":true}' ;;
  *"repos/owner/app/actions/oidc/customization/sub"*) echo '{"use_immutable_subject":true}' ;;
  *"repos/owner/infra"*) echo '{"owner":{"login":"owner","id":101},"name":"infra","id":201}' ;;
  *"repos/owner/app"*) echo '{"owner":{"login":"owner","id":101},"name":"app","id":202}' ;;
  *"repos/owner/gitops/rulesets/301"*) echo '{"bypass_actors":[],"rules":[{"type":"pull_request","parameters":{"require_code_owner_review":true}},{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"validate"}]}}]}' ;;
  *"repos/owner/gitops/rulesets"*) echo '[{"id":301,"name":"main-protection","enforcement":"active","target":"branch"}]' ;;
  *) printf 'unexpected gh invocation: %s\n' "$*" >&2; exit 97 ;;
esac
EOF
chmod +x "$tmp_dir/bin/aws" "$tmp_dir/bin/dig" "$tmp_dir/bin/gh"

runtime_file="$tmp_dir/secrets/runtime.json"
database_file="$tmp_dir/secrets/database.json"
cat >"$runtime_file" <<'JSON'
{"API_KEY":"runtime-value"}
JSON
cat >"$database_file" <<'JSON'
{"DB_HOST":"db.internal","DB_PORT":"5432","DB_NAME":"commerce","DB_USER":"commerce","DB_PASSWORD":"database-value"}
JSON

base_env=(
  AWS_PROFILE=course AWS_REGION=ap-northeast-2 STATE_BUCKET_NAME=state-bucket
  LAB_PROJECT_NAME=course HOSTED_ZONE_ID=Z123 ROOT_DOMAIN=example.invalid
  INFRA_GH_REPO=owner/infra APP_GH_REPO=owner/app GITOPS_GH_REPO=owner/gitops
  COURSE_CHECK_BIN_DIR="$tmp_dir/bin"
)

run_check() {
  env "${base_env[@]}" "$@" bash "$root/scripts/course-check.sh" ch02
}

output=$(run_check RUNTIME_SECRET_JSON_FILE="$runtime_file" DB_SECRET_JSON_FILE="$database_file")
grep -Fq 'secret JSON key 구조가 유효하며 값은 출력하지 않았습니다.' <<<"$output"
grep -Fq '[STATIC] SIMULATED_CLOUD_CONTRACT' <<<"$output"
! grep -Fq 'runtime-value' <<<"$output"
! grep -Fq 'database-value' <<<"$output"

expect_fail() {
  local expected=$1
  shift
  local output status
  set +e
  output=$(run_check "$@" 2>&1)
  status=$?
  set -e
  [[ "$status" -ne 0 ]]
  grep -Fq "$expected" <<<"$output"
  ! grep -Fq 'runtime-value' <<<"$output"
  ! grep -Fq 'database-value' <<<"$output"
}

expect_fail 'RUNTIME_SECRET_JSON_FILE과 DB_SECRET_JSON_FILE은 함께 설정해야 합니다.' \
  RUNTIME_SECRET_JSON_FILE="$runtime_file"
expect_fail 'SECRET_JSON_FILE은 더 이상 지원하지 않습니다.' \
  SECRET_JSON_FILE="$runtime_file"

cat >"$tmp_dir/secrets/runtime-empty.json" <<'JSON'
{"API_KEY":""}
JSON
expect_fail 'runtime secret JSON은 API_KEY만 포함해야 합니다.' \
  RUNTIME_SECRET_JSON_FILE="$tmp_dir/secrets/runtime-empty.json" DB_SECRET_JSON_FILE="$database_file"

cat >"$tmp_dir/secrets/runtime-mixed.json" <<'JSON'
{"API_KEY":"runtime-value","DB_PASSWORD":"database-value"}
JSON
expect_fail 'runtime secret JSON은 API_KEY만 포함해야 합니다.' \
  RUNTIME_SECRET_JSON_FILE="$tmp_dir/secrets/runtime-mixed.json" DB_SECRET_JSON_FILE="$database_file"

cat >"$tmp_dir/secrets/database-mixed.json" <<'JSON'
{"API_KEY":"runtime-value","DB_HOST":"db.internal","DB_PORT":"5432","DB_NAME":"commerce","DB_USER":"commerce","DB_PASSWORD":"database-value"}
JSON
expect_fail 'database secret JSON은 DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD만 포함해야 합니다.' \
  RUNTIME_SECRET_JSON_FILE="$runtime_file" DB_SECRET_JSON_FILE="$tmp_dir/secrets/database-mixed.json"

mkdir -p "$tmp_dir/git-worktree"
git -C "$tmp_dir/git-worktree" init -q
cat >"$tmp_dir/git-worktree/runtime.json" <<'JSON'
{"API_KEY":"runtime-value"}
JSON
expect_fail 'secret JSON은 Git worktree 밖에 두어야 합니다:' \
  RUNTIME_SECRET_JSON_FILE="$tmp_dir/git-worktree/runtime.json" DB_SECRET_JSON_FILE="$database_file"

echo 'PASS: split runtime/database secret JSON contract'
