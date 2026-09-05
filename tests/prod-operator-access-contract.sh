#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
variables="$root/environments/prod/02-eks/variables.tf"

rg -Uq 'variable "cluster_endpoint_public_access" \{[\s\S]*?default[[:space:]]*=[[:space:]]*false' "$variables"
grep -q 'variable "operator_access"' "$variables"
test -f "$root/scripts/prod-operator-access-check.sh"
rg -q 'associate_public_ip_address[[:space:]]*=[[:space:]]*false' "$root/modules/compute/operator-access/main.tf"
rg -q 'http_tokens[[:space:]]*=[[:space:]]*"required"' "$root/modules/compute/operator-access/main.tf"
! rg -q 'key_name[[:space:]]*=' "$root/modules/compute/operator-access/main.tf"

bash "$root/scripts/prod-operator-access-check.sh" --validate-only \
  --evidence "$root/tests/fixtures/operator-access-valid.json" >/dev/null
set +e
output=$(bash "$root/scripts/prod-operator-access-check.sh" --validate-only \
  --evidence "$root/tests/fixtures/operator-access-invalid-mode.json" 2>&1)
check_status=$?
set -e
[[ "$check_status" -ne 0 ]] && grep -Fq 'OPERATOR_ACCESS_MODE_INVALID' <<<"$output"

echo 'PASS: production operator access is private and SSM-only.'
