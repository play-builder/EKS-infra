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

jq . "$tmp_dir/alert-delivery.json" >"$tmp_dir/alert-delivery-valid.json"
export COURSE_FAKE_CLOUD_LOG="$tmp_dir/invalid-timestamp-cloud.log"
for timestamp_case in \
  'invalid-calendar|2020-02-30T00:00:00Z' \
  'fractional|2020-03-01T00:00:00.123Z' \
  'offset|2020-03-01T09:00:00+09:00' \
  'future|2026-09-03T10:31:00Z'; do
  IFS='|' read -r label value <<<"$timestamp_case"
  : >"$COURSE_FAKE_CLOUD_LOG"
  jq --arg value "$value" '.observedAt=$value' "$tmp_dir/alert-delivery-valid.json" >"$tmp_dir/alert-delivery.json"
  if run_ch16_fixture "$root" "$tmp_dir" "$tmp_dir/invalid-$label.json" >/dev/null 2>&1; then
    echo "alert delivery $label observedAt must be rejected" >&2
    exit 1
  fi
  [[ ! -e "$tmp_dir/invalid-$label.json" ]]
  [[ ! -s "$COURSE_FAKE_CLOUD_LOG" ]] || {
    echo "alert delivery $label observedAt must fail before cloud queries" >&2
    exit 1
  }
done
unset COURSE_FAKE_CLOUD_LOG
jq . "$tmp_dir/alert-delivery-valid.json" >"$tmp_dir/alert-delivery.json"

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
