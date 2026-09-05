#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workflow="$root/.github/workflows/terraform-validate.yml"

rg -Uq 'reviewed-plan-apply:[\s\S]*needs:[[:space:]]*reviewed-plan' "$workflow"
rg -q 'ea165f8d65b6e75b540449e92b4886f43607fa02' "$workflow"
rg -q 'd3f86a106a0bac45b974a628896c90dbdf5c8093' "$workflow"
rg -Uq 'reviewed-plan-apply:[\s\S]*actions:[[:space:]]*read' "$workflow"
rg -q 'actions/runs/\$GITHUB_RUN_ID/approvals' "$workflow"
rg -q 'bind-saved-plan-approval.sh' "$workflow"
rg -q 'aws sts get-caller-identity' "$workflow"
rg -q 'GITHUB_TRIGGERING_ACTOR.*GITHUB_RUN_ID.*apply' "$workflow"
rg -Fq 'PLAN_REQUEST_IDENTITY: ${{ github.triggering_actor }}' "$workflow"
rg -q 'terraform-apply-.*terraform_root' "$workflow"
rg -Fq 'BACKEND_BUCKET: ${{ vars.STATE_BUCKET_NAME }}' "$workflow"
! rg -q '^[[:space:]]*backend_bucket:' "$workflow"
rg -q 'fail APPROVAL_INVALID' "$root/scripts/verify-saved-plan.sh"
rg -q 'TERRAFORM_BINARY_MISMATCH' "$root/scripts/verify-saved-plan.sh"
rg -q 'PROVIDER_LOCK_MISMATCH' "$root/scripts/verify-saved-plan.sh"
rg -q 'PLAN_CHECKSUM_INVALID' "$root/scripts/verify-saved-plan.sh"
rg -q 'terraform_plan_binary_path' "$root/scripts/create-saved-plan.sh"
rg -q -- '-lockfile=readonly' "$root/scripts/create-saved-plan.sh"
rg -q -- '-lockfile=readonly' "$root/scripts/terraform-drift-check.sh"
rg -q 'cleanup_apply_saved_plans' "$root/scripts/final-cleanup.sh"
rg -q 'SAVED_DESTROY_PLAN_NOT_DELETE_ONLY' "$root/scripts/lib/cleanup-evidence.sh"
rg -q 'OPERATOR_ACCESS_ROLE_TRUST_INVALID' "$root/modules/compute/operator-access/variables.tf"
rg -q 'send-command' "$root/scripts/prod-operator-access-check.sh"
rg -q 'kubectl auth can-i get pods' "$root/scripts/prod-operator-access-check.sh"
rg -q 'awscli-2' "$root/modules/compute/operator-access/bootstrap.sh.tftpl"
! rg -q 'awscli2' "$root/modules/compute/operator-access/bootstrap.sh.tftpl"
rg -q 'logs:PutLogEvents' "$root/modules/networking/vpc/main.tf"
! rg -q 'Resource = "\*"' "$root/modules/networking/vpc/main.tf"
for setting in STATE_BUCKET_NAME TERRAFORM_PLAN_ROLE_ARN TERRAFORM_APPLY_ROLE_ARN; do
  rg -q "$setting" "$root/docs/runbook.md"
done

echo 'PASS: Batch 1 review remediation controls are present.'
