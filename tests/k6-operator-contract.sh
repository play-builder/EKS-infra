#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/helpers/ch16-fake-environment.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
setup_ch16_fake_environment "$tmp_dir"

run_ch16_fixture "$root" "$tmp_dir" "$tmp_dir/slo.json" >/dev/null

if FAKE_K6_BAD=true run_ch16_fixture "$root" "$tmp_dir" "$tmp_dir/unbounded.json" >/dev/null 2>&1; then
  echo 'k6 evidence without an explicit compute-cost boundary must fail' >&2
  exit 1
fi
[[ ! -e "$tmp_dir/unbounded.json" ]]

echo 'PASS: Ch16 k6 controller and run carry readiness, duration, rate, and cost boundaries'
