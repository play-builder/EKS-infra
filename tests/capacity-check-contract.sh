#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

output=$(bash "$root/scripts/capacity-check.sh" --mode design \
  --input "$root/tests/fixtures/capacity-go.json")
grep -Fq '"decision": "GO"' <<<"$output"
grep -Fq 'PASS: [STATIC]' <<<"$output"
! grep -Fq '[CLOUD_RUNTIME]' <<<"$output"

set +e
output=$(bash "$root/scripts/capacity-check.sh" --mode design \
  --input "$root/tests/fixtures/capacity-no-go.json" 2>&1)
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo 'expected capacity NO_GO to fail' >&2
  exit 1
fi
grep -Fq 'NO_GO' <<<"$output"

tmp_file=$(mktemp)
trap 'rm -f -- "$tmp_file"' EXIT
jq '.unexpected=true' "$root/tests/fixtures/capacity-go.json" >"$tmp_file"
set +e
bash "$root/scripts/capacity-check.sh" --mode design --input "$tmp_file" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo 'expected additional property to fail' >&2
  exit 1
fi

jq '.workload.replicas=3.5' "$root/tests/fixtures/capacity-go.json" >"$tmp_file"
set +e
bash "$root/scripts/capacity-check.sh" --mode design --input "$tmp_file" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -eq 0 ]]; then
  echo 'expected fractional replica count to fail' >&2
  exit 1
fi

expect_timestamp_rejected() {
  local label=$1 field=$2 value=$3
  jq --arg field "$field" --arg value "$value" '.[$field]=$value' \
    "$root/tests/fixtures/capacity-go.json" >"$tmp_file"
  if bash "$root/scripts/capacity-check.sh" --mode design --input "$tmp_file" >/dev/null 2>&1; then
    echo "expected $label capacity timestamp to fail" >&2
    exit 1
  fi
}

expect_timestamp_rejected observed-invalid-calendar observedAt '2020-02-30T00:00:00Z'
expect_timestamp_rejected observed-fractional observedAt '2020-03-01T00:00:00.123Z'
expect_timestamp_rejected observed-offset observedAt '2020-03-01T09:00:00+09:00'
expect_timestamp_rejected expires-invalid-calendar expiresAt '2099-02-31T00:00:00Z'
expect_timestamp_rejected expires-fractional expiresAt '2099-03-01T00:00:00.123Z'
expect_timestamp_rejected expires-offset expiresAt '2099-03-01T09:00:00+09:00'

echo 'PASS: normalized capacity GO and NO_GO contract'
