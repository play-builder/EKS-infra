#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/scripts/lib/terraform-plan-contract.sh"
while IFS='|' read -r layer backend key; do
  [[ $(terraform_plan_expected_backend_for_root "$layer") == "$backend" ]]
  [[ $(terraform_plan_expected_backend_key_for_root "$layer") == "$key" ]]
done <<'ROOTS'
environments/prod/00-finops|environments/prod/config/finops.tfbackend|prod/00-finops/terraform.tfstate
environments/prod/03-database|environments/prod/config/database.tfbackend|prod/03-database/terraform.tfstate
environments/recovery/03-database|environments/recovery/config/database.tfbackend|recovery/03-database/terraform.tfstate
terraform/platform-backup|terraform/platform-backup/backend.tfbackend|shared/platform-backup/terraform.tfstate
ROOTS
for bad in environments/dev/03-database environments/prod/../prod/03-database terraform/not-backup; do
  if (terraform_plan_expected_backend_for_root "$bad") >/dev/null 2>&1; then exit 1; fi
done
ruby - "$root" <<'RUBY'
require 'yaml'
root = ARGV.fetch(0)
w = YAML.load_file("#{root}/.github/workflows/terraform-validate.yml")
inputs = w.fetch('on', w[true]).fetch('workflow_dispatch').fetch('inputs')
choices = inputs.fetch('terraform_root').fetch('options')
matrix = w.fetch('jobs').fetch('validate').fetch('strategy').fetch('matrix').fetch('root')
%w[environments/prod/03-database environments/recovery/03-database].each { |r| raise r unless choices.include?(r) && matrix.include?(r) }
%w[environments/prod/00-finops terraform/platform-backup].each { |r| raise "operator-only #{r}" unless !choices.include?(r) && matrix.include?(r) }
RUBY
echo 'PASS: canonical enterprise roots and separate operator-only lanes'
