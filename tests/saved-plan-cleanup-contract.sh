#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

for environment in dev prod; do
  main_file="$root/environments/$environment/04-workloads/argocd/main.tf"
  if rg -q 'prevent_destroy[[:space:]]*=[[:space:]]*true' "$main_file"; then
    echo "$environment workload ownership marker blocks reviewed destroy plans" >&2
    exit 1
  fi
done

for script in scripts/checkpoint-teardown.sh scripts/final-cleanup.sh; do
  script_path="$root/$script"
  if rg -q 'terraform .*state[[:space:]]+rm|terraform .*destroy|-[[:alnum:]-]*target|-auto-approve' "$script_path"; then
    echo "$script contains a cleanup mutation that bypasses the reviewed saved plan" >&2
    exit 1
  fi
  rg -q 'cleanup_apply_saved_plans' "$script_path" || {
    echo "$script must apply the reviewed saved plans through the shared verifier" >&2
    exit 1
  }
done

rg -q 'cleanup_validate_saved_destroy_plan' "$root/scripts/cleanup-preflight.sh" || {
  echo 'cleanup preflight must route every binary plan through the shared semantic verifier' >&2
  exit 1
}
rg -q 'terraform .*show[[:space:]]+-json' "$root/scripts/lib/cleanup-evidence.sh" || {
  echo 'shared cleanup verifier must inspect saved binary plans without retaining raw plan JSON' >&2
  exit 1
}

if rg -q 'REVIEWED_DESTROY_PLAN_JSON' "$root/README.md" "$root/docs/runbook.md"; then
  echo 'operator docs must not persist raw Terraform plan JSON as the cleanup input' >&2
  exit 1
fi

rg -q 'SAVED_DESTROY_PLAN_MANIFEST' "$root/README.md" "$root/docs/runbook.md" || {
  echo 'operator docs must use the reviewed saved-plan manifest' >&2
  exit 1
}

echo 'PASS: cleanup consumes only digest-bound reviewed saved plans'
