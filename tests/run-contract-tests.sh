#!/usr/bin/env bash
set -Eeuo pipefail
export PYTHONDONTWRITEBYTECODE=1

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

tests=(
  enterprise-root-map-contract.sh
  scheduled-drift-contract.sh
  enterprise-ownership-boundary-contract.sh
  eks-node-rollout-contract.sh
  finops-readiness-contract.sh
  finops-saved-plan-contract.sh
  install-trivy-contract.sh
  bootstrap-mini-commerce-db-contract.sh
  rds-recovery-contract.sh
  platform-rebuild-dr-contract.sh
  amp-slo-drill-contract.sh
  argocd-backup-contract.sh
  ecr-enhanced-scanning-contract.sh
  argocd-ha-contract.sh
  access-entry-review-contract.sh
  mng-autoscaler-drill-contract.sh
  eks-upgrade-preflight-contract.sh
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
  saved-plan-apply-workflow-contract.sh
  terraform-drift-contract.sh
  terraform-drift-exit-code-contract.sh
  final-cleanup-contract.sh
)

for test_file in "${tests[@]}"; do
  echo "RUN: tests/$test_file"
  bash "$root/tests/$test_file"
done

python3 "$root/tests/enterprise-cleanup-contract.py"
python3 "$root/tests/log-key-cleanup-contract.py"
python3 "$root/tests/lua-installer-contract.py"
python3 "$root/tests/platform-image-mirror-test.py"

echo 'PASS: offline semantic contract suite'
echo 'Tool-backed Terraform/Helm/PromQL/SDK gates: bash tests/run-enterprise-static-tests.sh (separate prerequisites; not implied by this PASS).'
