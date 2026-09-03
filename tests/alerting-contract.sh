#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/helpers/ch16-fake-environment.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
setup_ch16_fake_environment "$tmp_dir"

output=$(run_ch16_fixture "$root" "$tmp_dir" "$tmp_dir/slo.json")
grep -Fq '[STATIC] SIMULATED_CLOUD_CONTRACT' <<<"$output"
jq -e '.evidenceGrade == "STATIC" and .status == "PASS"' "$tmp_dir/slo.json" >/dev/null

if FAKE_SNS_PENDING=true run_ch16_fixture "$root" "$tmp_dir" "$tmp_dir/pending.json" >/dev/null 2>&1; then
  echo 'PendingConfirmation must be routing-only evidence, not delivery proof' >&2
  exit 1
fi
[[ ! -e "$tmp_dir/pending.json" ]]

if FAKE_SNS_WRONG_SOURCE=true run_ch16_fixture "$root" "$tmp_dir" "$tmp_dir/wrong-source.json" >/dev/null 2>&1; then
  echo 'SNS policy for another AMP workspace/account must not prove delivery authorization' >&2
  exit 1
fi
[[ ! -e "$tmp_dir/wrong-source.json" ]]

jq '.resolved.delivered=false' "$tmp_dir/alert-delivery.json" >"$tmp_dir/incomplete-delivery.json"
mv "$tmp_dir/incomplete-delivery.json" "$tmp_dir/alert-delivery.json"
if run_ch16_fixture "$root" "$tmp_dir" "$tmp_dir/incomplete.json" >/dev/null 2>&1; then
  echo 'Firing-only evidence must not prove resolved delivery' >&2
  exit 1
fi

echo 'PASS: AMP alerting requires active definitions, confirmed SNS, and Firing/Resolved delivery'
