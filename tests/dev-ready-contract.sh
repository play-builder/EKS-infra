#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/task5-fixture-helpers.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

for region in ap-northeast-2 us-east-1; do
  ready="$root/tests/fixtures/dev-ready-$region.json"
  deployment="$tmp_dir/deployment-$region.json"
  slo="$tmp_dir/slo-$region.json"
  make_dev_handoff "$ready" "$deployment" "$slo"
  output=$(AWS_REGION="$region" AWS_ACCOUNT_ID=123456789012 \
    bash "$root/scripts/dev-ready-check.sh" "$deployment" "$slo" "$ready")
  grep -Fq 'PASS: [STATIC]' <<<"$output"
  ! grep -Fq '[CLOUD_RUNTIME]' <<<"$output"
done

deployment="$tmp_dir/deployment-invalid.json"
slo="$tmp_dir/slo-invalid.json"
make_dev_handoff "$root/tests/fixtures/dev-ready-ap-northeast-2.json" "$deployment" "$slo"
jq '.unexpected=true' "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$tmp_dir/dev-ready-extra.json"
jq '.evidenceGrade="STATIC"' "$deployment" >"$tmp_dir/static-deployment.json"
jq '.image.indexDigest="sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"' \
  "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$tmp_dir/dev-ready-mismatch.json"

run_rejected() {
  local deployment_file=$1 ready_file=$2 status
  set +e
  AWS_REGION=ap-northeast-2 AWS_ACCOUNT_ID=123456789012 bash "$root/scripts/dev-ready-check.sh" \
    "$deployment_file" "$slo" "$ready_file" >/dev/null 2>&1
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    echo "expected DEV_READY rejection: $ready_file" >&2
    exit 1
  fi
}

run_rejected "$deployment" "$root/tests/fixtures/dev-ready-invalid-aliases.json"
run_rejected "$deployment" "$tmp_dir/dev-ready-extra.json"
run_rejected "$tmp_dir/static-deployment.json" "$root/tests/fixtures/dev-ready-ap-northeast-2.json"
run_rejected "$deployment" "$tmp_dir/dev-ready-mismatch.json"

echo 'PASS: canonical DEV_READY and intermediate evidence contract'
