#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

tests=(
  course-check-contract.sh
  evidence-common-contract.sh
  ch10-runtime-contract.sh
  stateful-contract.sh
  oidc-external-provider-contract.sh
  oidc-ownership-handoff-contract.sh
  ecr-lifecycle-preview-contract.sh
  secret-json-contract.sh
  network-policy-runtime-contract.sh
  prod-network-ha-contract.sh
  prod-operator-access-contract.sh
  external-secrets-owner-handoff-contract.sh
  secret-freshness-contract.sh
  alerting-contract.sh
  k6-operator-contract.sh
  dev-evidence-handoff-contract.sh
  snapshot-quiesce-contract.sh
  snapshot-recovery-contract.sh
  dev-ready-contract.sh
  prod-bootstrap-contract.sh
  capacity-check-contract.sh
  prod-design-preflight-contract.sh
  prod-preflight-contract.sh
  prod-live-capacity-check-contract.sh
  prod-baseline-check-contract.sh
  chaos-mesh-contract.sh
  game-day-capacity-check-contract.sh
  ownership-inventory-contract.sh
  retained-identity-contract.sh
  kubernetes-pre-destroy-retained-contract.sh
  residual-retained-kubernetes-contract.sh
  cleanup-preflight-contract.sh
  in-flight-zero-contract.sh
  checkpoint-teardown-contract.sh
  mandatory-platform-tags-contract.sh
  batch1-review-contract.sh
  saved-plan-create-contract.sh
  saved-plan-identity-contract.sh
  terraform-drift-contract.sh
  terraform-drift-exit-code-contract.sh
  final-cleanup-contract.sh
)

for test_file in "${tests[@]}"; do
  echo "RUN: tests/$test_file"
  bash "$root/tests/$test_file"
done

echo 'PASS: offline semantic contract suite'
