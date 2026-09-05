#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
required=(PlatformInstanceId Owner CostCenter Environment)

for key in "${required[@]}"; do
  rg -q "$key" "$root/environments/prod/01-network/main.tf"
  rg -q "$key" "$root/environments/prod/02-eks/main.tf"
done
for variable_name in platform_instance_id owner cost_center; do
  rg -q "variable \"$variable_name\"" "$root/environments/prod/01-network/variables.tf"
  rg -q "variable \"$variable_name\"" "$root/environments/prod/02-eks/variables.tf"
  rg -q "^$variable_name[[:space:]]*=" "$root/environments/prod/01-network/terraform.tfvars.example"
  rg -q "^$variable_name[[:space:]]*=" "$root/environments/prod/02-eks/terraform.tfvars.example"
done

rg -Uq 'variable "tags"[\s\S]*PLATFORM_TAGS_REQUIRED' "$root/modules/networking/vpc/variables.tf"
rg -Uq 'variable "tags"[\s\S]*PLATFORM_TAGS_REQUIRED' "$root/modules/compute/operator-access/variables.tf"

echo 'PASS: production network and operator resources require the platform ownership tag set.'
