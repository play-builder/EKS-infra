#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
valid="$root/tests/fixtures/oidc-ownership-handoff-valid.json"

output=$(bash "$root/scripts/oidc-ownership-handoff.sh" --evidence "$valid" --validate-only)
grep -Fq 'VALID: course.oidc-ownership-handoff/v1' <<<"$output"

invalid=$(mktemp)
trap 'rm -f -- "$invalid"' EXIT
jq '.destinationState.imported=false' "$valid" >"$invalid"
if bash "$root/scripts/oidc-ownership-handoff.sh" --evidence "$invalid" --validate-only >/dev/null 2>&1; then
  echo 'expected unimported destination to fail' >&2
  exit 1
fi

echo 'PASS: OIDC ownership handoff evidence contract'
