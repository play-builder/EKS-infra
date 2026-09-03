#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"

cat >"$tmp_dir/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$COURSE_FAKE_AWS_LOG"
if [[ "$1 $2" == "sts get-caller-identity" ]]; then
  account=$(jq -r '.fixtureCallerAccount // "123456789012"' "$COURSE_OIDC_FIXTURE")
  jq -n --arg account "$account" '{Account:$account}'
elif [[ "$1 $2" == "iam get-open-id-connect-provider" ]]; then
  cat "$COURSE_OIDC_FIXTURE"
else
  exit 97
fi
EOF
chmod +x "$tmp_dir/bin/aws"

arn=arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com

run_case() {
  local fixture=$1 expected=$2 pattern=$3 status output log
  log="$tmp_dir/${fixture}.log"
  set +e
  output=$(AWS_PROFILE=course AWS_REGION=ap-northeast-2 COURSE_CHECK_BIN_DIR="$tmp_dir/bin" \
    COURSE_FAKE_AWS_LOG="$log" COURSE_OIDC_FIXTURE="$root/tests/fixtures/$fixture" \
    bash "$root/scripts/validate-external-oidc.sh" "$arn" 2>&1)
  status=$?
  set -e
  [[ "$status" -eq "$expected" ]]
  grep -Fq "$pattern" <<<"$output"
  grep -Fq -- '--region ap-northeast-2' "$log"
}

run_case oidc-external-provider-valid.json 0 '[STATIC] SIMULATED_CLOUD_CONTRACT'
run_case oidc-external-provider-wrong-account.json 1 'OIDC_ACCOUNT_MISMATCH'
run_case oidc-external-provider-wrong-url.json 1 'OIDC_ISSUER_MISMATCH'
run_case oidc-external-provider-missing-audience.json 1 'OIDC_AUDIENCE_MISSING'

echo 'PASS: external OIDC live-identity contract'
