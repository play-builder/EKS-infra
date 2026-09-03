#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then
  PATH="$COURSE_CHECK_BIN_DIR:$PATH"
fi

fail() { printf 'ERROR: %s\n' "$1" >&2; exit 1; }
[[ $# -ge 2 ]] || fail 'usage: ecr-lifecycle-preview.sh <repository> <retained-digest>...'
: "${AWS_PROFILE:?AWS_PROFILE is required}"
: "${AWS_REGION:?AWS_REGION is required}"
[[ "$AWS_REGION" == "ap-northeast-2" || "$AWS_REGION" == "us-east-1" ]] || fail 'UNSUPPORTED_REGION'

repository=$1
shift
for digest in "$@"; do
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "invalid digest: $digest"
done

aws ecr start-lifecycle-policy-preview --repository-name "$repository" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" --output json >/dev/null
aws ecr wait lifecycle-policy-preview-complete --repository-name "$repository" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION"
preview=$(aws ecr get-lifecycle-policy-preview --repository-name "$repository" \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" --output json)

[[ $(jq -r '.status' <<<"$preview") == COMPLETE ]] || fail 'NO_GO: lifecycle preview did not complete'
for digest in "$@"; do
  if jq -e --arg digest "$digest" 'any(.previewResults[]?; .imageDigest == $digest and .action.type == "EXPIRE")' \
    <<<"$preview" >/dev/null; then
    fail "NO_GO: retained rollback index would expire: $digest"
  fi
done

if [[ "${COURSE_CHECK_DETAIL_ONLY:-false}" == true ]]; then
  echo 'DETAIL: GO: retained rollback indexes survive preview.'
elif [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then
  echo 'PASS: [STATIC] SIMULATED_CLOUD_CONTRACT GO: retained rollback indexes survive preview.'
else
  echo 'PASS: [CLOUD_RUNTIME] GO: retained rollback indexes survive preview.'
fi
