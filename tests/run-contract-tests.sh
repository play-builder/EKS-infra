#!/usr/bin/env bash
set -Eeuo pipefail
export PYTHONDONTWRITEBYTECODE=1

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

tests=(
  ci-runner-prerequisites-contract.sh
  enterprise-root-map-contract.sh
  scheduled-drift-contract.sh
  enterprise-ownership-boundary-contract.sh
  eks-lifecycle-test.py
  finops_readiness_test.py
  finops_saved_plan_test.py
  install-trivy-contract.sh
  bootstrap-mini-commerce-db-contract.py
  rds-recovery-contract.py
  platform-rebuild-dr-contract.py
  amp-slo-drill-contract.py
  argocd-backup-contract.py
  supply-chain-test.py
  argocd-ha-test.py
  access-entry-review-test.py
  mng-autoscaler-test.py
  saved-plan-artifact-contract.sh
  saved-plan-preflight-recovery-contract.sh
  saved-plan-execution-contract.sh
  workflow-supply-chain-contract.sh
  workflow-supply-chain-contract.test.sh
  evidence-common-contract.sh
  foundation-contract.sh
  dev-capture-contract.sh
  stateful-contract.sh
  oidc-external-provider-contract.sh
  oidc-ownership-handoff-contract.sh
  ecr-lifecycle-preview-contract.sh
  secret-json-contract.sh
  network-policy-runtime-contract.sh
  prod-operator-access-contract.sh
  external-secrets-owner-handoff-contract.sh
  secret-freshness-contract.sh
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
  saved-plan-create-contract.sh
  saved-plan-identity-contract.sh
  saved-plan-apply-workflow-contract.sh
  terraform-drift-exit-code-contract.sh
  final-cleanup-contract.sh
)

for test_file in "${tests[@]}"; do
  echo "RUN: tests/$test_file"
  case "$test_file" in
    *.py) python3 -B "$root/tests/$test_file" ;;
    *.sh) bash "$root/tests/$test_file" ;;
    *) echo "Unsupported test entry: $test_file" >&2; exit 2 ;;
  esac
done

python3 "$root/tests/enterprise-cleanup-contract.py"
python3 "$root/tests/enterprise-cleanup-resume-contract.py"
python3 "$root/tests/project-terraform-inputs-contract.py"
python3 "$root/tests/log-key-cleanup-contract.py"
python3 "$root/tests/lua-installer-contract.py"
python3 "$root/tests/platform-image-mirror-test.py"

echo 'PASS: offline semantic contract suite'
echo 'Tool-backed Terraform/Helm/PromQL/SDK gates are separate jobs in terraform-validate.yml; see docs/testing.md.'
