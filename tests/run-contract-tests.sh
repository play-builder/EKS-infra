#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

tests=(
  state-backend-contract.sh
  cluster-identity-contract.sh
  saved-plan-cleanup-contract.sh
  platform-telemetry-output-contract.sh
  course-check-contract.sh
  evidence-common-contract.sh
  ch10-runtime-contract.sh
  stateful-contract.sh
  oidc-external-provider-contract.sh
  oidc-ownership-handoff-contract.sh
  ecr-lifecycle-preview-contract.sh
  secret-json-contract.sh
  network-policy-runtime-contract.sh
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
  final-cleanup-contract.sh
)

for test_file in "${tests[@]}"; do
  echo "RUN: tests/$test_file"
  bash "$root/tests/$test_file"
done

terraform_tests=(
  "terraform/iam-github-oidc|tests/state-lock-policy.tftest.hcl"
  "terraform/iam-github-oidc|tests/ownership-and-ecr.tftest.hcl"
  "modules/addons/adot-collector|tests/telemetry-contract.tftest.hcl"
)

initialized_roots='|'
for test_case in "${terraform_tests[@]}"; do
  IFS='|' read -r terraform_root test_filter <<<"$test_case"
  if [[ "$initialized_roots" != *"|$terraform_root|"* ]]; then
    echo "INIT: $terraform_root"
    terraform -chdir="$root/$terraform_root" init -backend=false -input=false >/dev/null
    initialized_roots+="$terraform_root|"
  fi
  echo "RUN: $terraform_root/$test_filter"
  terraform -chdir="$root/$terraform_root" test -filter="$test_filter"
done

echo 'PASS: offline semantic contract suite'
