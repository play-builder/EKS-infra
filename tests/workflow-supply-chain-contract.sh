#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
workflow="$root/.github/workflows/terraform-validate.yml"
lock="$root/versions.lock.yaml"

locked_action_sha=$(yq -r '.tooling.trivyActionSha' "$lock")
locked_version=$(yq -r '.tooling.trivy' "$lock")
action_ref=$(yq -r '.jobs.security.steps[] | select(.name == "Scan Terraform with Trivy") | .uses' "$workflow")
scanner_version=$(yq -r '.jobs.security.steps[] | select(.name == "Scan Terraform with Trivy") | .with.version' "$workflow")
legacy_input=$(yq -r '.jobs.security.steps[] | select(.name == "Scan Terraform with Trivy") | .with."trivy-version" // ""' "$workflow")
skip_files=$(yq -r '.jobs.security.steps[] | select(.name == "Scan Terraform with Trivy") | .with."skip-files" // ""' "$workflow")

[[ "$locked_version" == '0.74.0' ]] || {
  echo 'versions.lock.yaml must retain the approved Trivy scanner release' >&2
  exit 1
}
[[ "$locked_action_sha" == 'ed142fd0673e97e23eac54620cfb913e5ce36c25' ]] || {
  echo 'versions.lock.yaml must retain the approved Trivy Action commit' >&2
  exit 1
}
[[ "$locked_action_sha" =~ ^[0-9a-f]{40}$ ]] || {
  echo 'Trivy Action lock must be a full lowercase commit SHA' >&2
  exit 1
}
[[ "$action_ref" == "aquasecurity/trivy-action@$locked_action_sha" ]] || {
  echo 'Trivy Action ref must match versions.lock.yaml' >&2
  exit 1
}
[[ "$scanner_version" == "v$locked_version" && "${scanner_version#v}" == "$locked_version" ]] || {
  echo 'Trivy scanner version input must match versions.lock.yaml' >&2
  exit 1
}
[[ -z "$legacy_input" ]] || {
  echo 'unsupported Trivy Action input trivy-version must not be used' >&2
  exit 1
}
[[ "$skip_files" == 'tests/fixtures/terraform-plan-noop-malformed.json' ]] || {
  echo 'Trivy config scan must exclude only the intentionally malformed negative fixture' >&2
  exit 1
}

echo 'PASS: Terraform security workflow pins the locked Trivy Action and scanner version'
