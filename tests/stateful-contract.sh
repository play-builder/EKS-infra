#!/usr/bin/env bash
set -Eeuo pipefail

repository_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

for environment in dev prod; do
  course_file="$repository_root/environments/$environment/03-platform/course.tf"
  variables_file="$repository_root/environments/$environment/03-platform/variables.tf"
  example_file="$repository_root/environments/$environment/03-platform/terraform.tfvars.example"

  grep -q 'resource "kubernetes_storage_class_v1" "course_gp3"' "$course_file"
  grep -q 'name = "course-gp3"' "$course_file"
  grep -Eq 'storage_provisioner[[:space:]]*=[[:space:]]*"ebs.csi.aws.com"' "$course_file"
  grep -Eq 'reclaim_policy[[:space:]]*=[[:space:]]*"Delete"' "$course_file"
  grep -Eq 'volume_binding_mode[[:space:]]*=[[:space:]]*"WaitForFirstConsumer"' "$course_file"
  grep -Eq 'allow_volume_expansion[[:space:]]*=[[:space:]]*true' "$course_file"
  grep -Eq '"encrypted"[[:space:]]*=[[:space:]]*"true"' "$course_file"
  grep -q 'variable "enable_course_storage_class"' "$variables_file"
  grep -q 'enable_course_storage_class.*=.*true' "$example_file"
done

for variables_file in \
  "$repository_root/environments/dev/03-platform/variables.tf" \
  "$repository_root/environments/prod/03-platform/variables.tf"; do
  awk '
    /variable "ebs_csi_driver_use_aws_managed_policy"/ { in_variable = 1 }
    in_variable && /default[[:space:]]*=[[:space:]]*true/ { found = 1 }
    in_variable && /^}/ { exit }
    END { exit(found ? 0 : 1) }
  ' "$variables_file"
done

grep -q 'check_stateful()' "$repository_root/scripts/course-check.sh"
grep -q 'stateful) check_stateful' "$repository_root/scripts/course-check.sh"
grep -q 'storageclass/course-gp3' "$repository_root/scripts/course-check.sh"
grep -q 'app.kubernetes.io/component=database' "$repository_root/scripts/course-check.sh"
grep -q '/products/1/inventory' "$repository_root/scripts/course-check.sh"
grep -q '/orders' "$repository_root/scripts/course-check.sh"
grep -q 'Idempotency-Key:' "$repository_root/scripts/course-check.sh"

grep -q 'scripts/\*\*' "$repository_root/.github/workflows/terraform-validate.yml"
grep -q 'tests/\*\*' "$repository_root/.github/workflows/terraform-validate.yml"
grep -q 'bash tests/stateful-contract.sh' "$repository_root/.github/workflows/terraform-validate.yml"

governance_file="$repository_root/terraform/github-governance/main.tf"
grep -q 'resource "github_repository" "gitops_settings"' "$governance_file"
grep -q 'allow_auto_merge       = true' "$governance_file"
grep -q 'allow_squash_merge     = true' "$governance_file"
grep -q 'allow_merge_commit     = false' "$governance_file"
grep -q 'allow_rebase_merge     = false' "$governance_file"
grep -q 'delete_branch_on_merge = true' "$governance_file"
grep -q 'resource "github_repository_vulnerability_alerts" "gitops"' "$governance_file"
grep -q 'enabled    = true' "$governance_file"

grep -q 'id: GIT-0001' "$repository_root/.trivyignore.yaml"
grep -q 'id: GIT-0003' "$repository_root/.trivyignore.yaml"

grep -q 'local before_id=' "$repository_root/scripts/course-check.sh"
grep -q 'check_ch05()' "$repository_root/scripts/course-check.sh"

echo "PASS: EKS Stateful storage and runtime checker contracts are valid."
