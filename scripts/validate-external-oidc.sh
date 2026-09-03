#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then
  PATH="$COURSE_CHECK_BIN_DIR:$PATH"
fi

fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
[[ $# -eq 1 ]] || fail 'usage: validate-external-oidc.sh <provider-arn>'
: "${AWS_PROFILE:?AWS_PROFILE is required}"
: "${AWS_REGION:?AWS_REGION is required}"
[[ "$AWS_REGION" == "ap-northeast-2" || "$AWS_REGION" == "us-east-1" ]] || fail 'UNSUPPORTED_REGION'

provider_arn=$1
arn_account=$(cut -d: -f5 <<<"$provider_arn")
caller=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --region "$AWS_REGION" --output json)
provider=$(aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$provider_arn" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" --output json)
caller_account=$(jq -r '.Account' <<<"$caller")

[[ "$arn_account" == "$caller_account" ]] || fail 'OIDC_ACCOUNT_MISMATCH'
[[ $(jq -r '.Url' <<<"$provider") == 'token.actions.githubusercontent.com' ]] || fail 'OIDC_ISSUER_MISMATCH'
jq -e 'any(.ClientIDList[]?; . == "sts.amazonaws.com")' <<<"$provider" >/dev/null || fail 'OIDC_AUDIENCE_MISSING'

if [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then
  echo 'PASS: [STATIC] SIMULATED_CLOUD_CONTRACT external OIDC identity is valid.'
else
  echo 'PASS: [CLOUD_RUNTIME] external OIDC identity is valid.'
fi
