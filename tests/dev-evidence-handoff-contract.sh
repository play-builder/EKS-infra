#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixtures="$root/tests/fixtures"
now="2026-09-03T10:30:00Z"

bash "$root/scripts/course-check.sh" ch15 --validate-evidence \
  "$fixtures/dev-deployment-valid.json" "$now" >/dev/null
bash "$root/scripts/course-check.sh" ch16 --validate-evidence \
  "$fixtures/dev-deployment-valid.json" "$fixtures/dev-slo-valid.json" "$now" >/dev/null

for invalid in dev-deployment-static.json dev-deployment-unhealthy.json; do
  if bash "$root/scripts/course-check.sh" ch15 --validate-evidence \
    "$fixtures/$invalid" "$now" >/dev/null 2>&1; then
    echo "invalid Ch15 evidence accepted: $invalid" >&2
    exit 1
  fi
done

for invalid in dev-slo-static.json dev-slo-failed.json dev-slo-identity-mismatch.json dev-slo-expired.json; do
  if bash "$root/scripts/course-check.sh" ch16 --validate-evidence \
    "$fixtures/dev-deployment-valid.json" "$fixtures/$invalid" "$now" >/dev/null 2>&1; then
    echo "invalid Ch16 evidence accepted: $invalid" >&2
    exit 1
  fi
done

echo 'PASS: Ch15/Ch16 runtime evidence handoff contract'
