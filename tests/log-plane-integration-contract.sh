#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TF_IN_AUTOMATION=1

for module in security/log-key security/waf-web-acl addons/container-insights eks/cluster networking/vpc; do
  terraform -chdir="$repo_root/modules/$module" init -backend=false -input=false -no-color
  terraform -chdir="$repo_root/modules/$module" validate -no-color
  terraform -chdir="$repo_root/modules/$module" test -no-color
done
for environment in dev prod; do
  for layer in 01-network 02-eks 03-platform; do
    terraform -chdir="$repo_root/environments/$environment/$layer" init -backend=false -input=false -lockfile=readonly -no-color
    terraform -chdir="$repo_root/environments/$environment/$layer" validate -no-color
    terraform -chdir="$repo_root/environments/$environment/$layer" test -filter=tests/logging.tftest.hcl -no-color
  done
done
printf '%s\n' 'LOG_PLANE_INTEGRATION_LOCAL_VERIFIED (mock providers; no AWS runtime evidence)'
