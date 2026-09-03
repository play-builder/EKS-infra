#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

roots=(
  environments/dev/02-eks
  environments/dev/03-platform
  environments/dev/04-workloads/argocd
  environments/prod/02-eks
  environments/prod/03-platform
  environments/prod/04-workloads/argocd
)

remote_state_count=0
bucket_binding_count=0

for relative_root in "${roots[@]}"; do
  main_file="$root/$relative_root/main.tf"
  variables_file="$root/$relative_root/variables.tf"
  example_file="$root/$relative_root/terraform.tfvars.example"

  block_count=$(awk '/^data "terraform_remote_state" / { count++ } END { print count + 0 }' "$main_file")
  binding_count=$(awk '/^[[:space:]]*bucket[[:space:]]*=[[:space:]]*var\.state_bucket_name[[:space:]]*$/ { count++ } END { print count + 0 }' "$main_file")
  remote_state_count=$((remote_state_count + block_count))
  bucket_binding_count=$((bucket_binding_count + binding_count))

  if ! awk '
    /^variable "state_bucket_name"[[:space:]]*\{/ { in_variable = 1; found = 1; next }
    in_variable && /^[[:space:]]*default[[:space:]]*=/ { exit 2 }
    in_variable && /^}/ { in_variable = 0 }
    END { if (!found) exit 1 }
  ' "$variables_file"; then
    echo "$relative_root must declare required state_bucket_name without a default" >&2
    exit 1
  fi

  if ! awk '/^[[:space:]]*state_bucket_name[[:space:]]*=/ { found = 1 } END { exit !found }' "$example_file"; then
    echo "$relative_root terraform.tfvars.example must set state_bucket_name explicitly" >&2
    exit 1
  fi

  if awk '/^[[:space:]]*bucket[[:space:]]*=/ && $0 !~ /=[[:space:]]*var\.state_bucket_name[[:space:]]*$/ { found = 1 } END { exit !found }' "$main_file"; then
    echo "$relative_root contains a remote-state bucket that is not var.state_bucket_name" >&2
    exit 1
  fi
done

[[ "$remote_state_count" -eq 10 ]] || {
  echo "expected 10 terraform_remote_state blocks, found $remote_state_count" >&2
  exit 1
}

[[ "$bucket_binding_count" -eq "$remote_state_count" ]] || {
  echo "expected every remote-state block to bind bucket to var.state_bucket_name; found $bucket_binding_count/$remote_state_count" >&2
  exit 1
}

echo 'PASS: all downstream remote states require the explicit state bucket input'
