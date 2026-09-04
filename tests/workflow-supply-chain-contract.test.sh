#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/workflow-supply-chain-contract.XXXXXX")
trap 'rm -rf -- "$workspace"' EXIT

mkdir -p "$workspace/tests" "$workspace/.github/workflows"
cp "$root/tests/workflow-supply-chain-contract.sh" "$workspace/tests/"
cp "$root/.github/workflows/terraform-validate.yml" "$workspace/.github/workflows/"
cp "$root/versions.lock.yaml" "$workspace/"

bash "$workspace/tests/workflow-supply-chain-contract.sh" >/dev/null

yq -i '.tooling.trivy = "0.73.0" | .tooling.trivyActionSha = "0123456789abcdef0123456789abcdef01234567"' \
  "$workspace/versions.lock.yaml"
yq -i '(.jobs.security.steps[] | select(.name == "Scan Terraform with Trivy") | .with.version) = "0.73.0"' \
  "$workspace/.github/workflows/terraform-validate.yml"
yq -i '(.jobs.security.steps[] | select(.name == "Scan Terraform with Trivy") | .uses) = "aquasecurity/trivy-action@0123456789abcdef0123456789abcdef01234567"' \
  "$workspace/.github/workflows/terraform-validate.yml"

if bash "$workspace/tests/workflow-supply-chain-contract.sh" >/dev/null 2>&1; then
  echo 'coordinated workflow and lock drift must be rejected' >&2
  exit 1
fi

echo 'PASS: coordinated Trivy workflow and lock drift is rejected'
