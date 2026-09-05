#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

for environment in dev prod; do
  eks_root="$root/environments/$environment/02-eks"

  if rg -q '^variable "cluster_name"' "$eks_root/variables.tf"; then
    echo "$environment 02-eks must not expose a duplicate cluster_name input" >&2
    exit 1
  fi

  if rg -q '^[[:space:]]*cluster_name[[:space:]]*=' "$eks_root/terraform.tfvars.example"; then
    echo "$environment 02-eks example must not define cluster_name" >&2
    exit 1
  fi

  if ! rg -q '^[[:space:]]*cluster_name[[:space:]]*=[[:space:]]*data\.terraform_remote_state\.network\.outputs\.eks_cluster_name$' "$eks_root/main.tf"; then
    echo "$environment 02-eks must derive local.cluster_name from the network state output" >&2
    exit 1
  fi

  expected_bindings=2
  [[ "$environment" == "dev" ]] && expected_bindings=3
  actual_bindings=$(awk '/^[[:space:]]*cluster_name[[:space:]]*=[[:space:]]*local\.cluster_name[[:space:]]*$/ { count++ } END { print count + 0 }' "$eks_root/main.tf")

  [[ "$actual_bindings" -eq "$expected_bindings" ]] || {
    echo "$environment EKS cluster and node groups must all consume local.cluster_name; found $actual_bindings/$expected_bindings" >&2
    exit 1
  }
done

echo 'PASS: EKS cluster and node groups derive identity only from network state'
