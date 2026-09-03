#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

tests=(
  course-check-contract.sh
  stateful-contract.sh
  oidc-external-provider-contract.sh
  oidc-ownership-handoff-contract.sh
  ecr-lifecycle-preview-contract.sh
  network-policy-runtime-contract.sh
  external-secrets-owner-handoff-contract.sh
  secret-freshness-contract.sh
  alerting-contract.sh
  k6-operator-contract.sh
  dev-evidence-handoff-contract.sh
)

for test_file in "${tests[@]}"; do
  echo "RUN: tests/$test_file"
  bash "$root/tests/$test_file"
done

echo 'PASS: offline semantic contract suite'
