#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
for fixture in "$root/tests/fixtures/drift-clean.json" "$root/tests/fixtures/drift-change.json"; do
  jq -e '
    .schemaVersion == "platform.terraform-drift/v1" and .evidenceGrade == "CLOUD_RUNTIME" and
    (.decision == "NO_DRIFT" or .decision == "DRIFT_DETECTED") and
    (.terraformRoot | test("^environments/(dev|prod)/")) and
    (.sourceSha | test("^[0-9a-f]{40}$")) and (.observedAt | fromdateiso8601) <= now
  ' "$fixture" >/dev/null
done
rg -q -- '-detailed-exitcode' "$root/scripts/terraform-drift-check.sh"
! rg -q 'terraform .*apply' "$root/scripts/terraform-drift-check.sh"
echo 'PASS: Terraform drift evidence is read-only and distinguishes drift.'
