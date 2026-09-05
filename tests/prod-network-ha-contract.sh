#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
example="$root/environments/prod/01-network/terraform.tfvars.example"

grep -Eq '^production_nat_topology[[:space:]]*=[[:space:]]*"per_az"$' "$example"
grep -Eq '^single_nat_gateway[[:space:]]*=[[:space:]]*false$' "$example"
grep -Eq '^one_nat_gateway_per_az[[:space:]]*=[[:space:]]*true$' "$example"
rg -q 'resource "aws_flow_log" "vpc"' "$root/modules/networking/vpc/main.tf"
rg -q 'traffic_type[[:space:]]*=[[:space:]]*"ALL"' "$root/modules/networking/vpc/main.tf"
rg -q 'output "nat_gateway_ids_by_az"' "$root/modules/networking/vpc/outputs.tf"

echo 'PASS: production network requires per-AZ NAT egress and VPC Flow Logs.'
