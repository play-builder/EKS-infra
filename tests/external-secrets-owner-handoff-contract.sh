#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixtures="$root/tests/fixtures"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

valid="$fixtures/external-secrets-handoff-valid.json"
dual="$fixtures/external-secrets-handoff-dual-owner.json"
adoption="$tmp_dir/adoption.json"
handoff_sha=$(shasum -a 256 "$valid" | awk '{print $1}')
jq --arg digest "sha256:$handoff_sha" '.handoffSha256=$digest' \
  "$fixtures/external-secrets-adoption-valid.json" >"$adoption"

bash "$root/scripts/external-secrets-owner-handoff.sh" validate-handoff \
  "$valid" "2026-09-03T12:00:00Z" >/dev/null

if bash "$root/scripts/external-secrets-owner-handoff.sh" validate-handoff \
  "$dual" "2026-09-03T12:00:00Z" >"$tmp_dir/dual.out" 2>&1; then
  echo "dual active reconcilers must be rejected" >&2
  exit 1
fi
grep -Fq 'PLATFORM_OWNER_HANDOFF_BLOCKED' "$tmp_dir/dual.out"

bash "$root/scripts/external-secrets-owner-handoff.sh" validate-adoption \
  "$valid" "$adoption" "2026-09-03T12:00:00Z" >/dev/null

jq '.terraform.planActions=["create"]' "$adoption" >"$tmp_dir/create.json"
if bash "$root/scripts/external-secrets-owner-handoff.sh" validate-adoption \
  "$valid" "$tmp_dir/create.json" "2026-09-03T12:00:00Z" >/dev/null 2>&1; then
  echo "non-no-op adoption must be rejected" >&2
  exit 1
fi

echo 'PASS: External Secrets single-writer handoff contract'
