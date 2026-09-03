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

echo 'PASS: normalized capacity GO and NO_GO contract'
