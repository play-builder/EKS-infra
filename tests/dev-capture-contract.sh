#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixtures="$root/tests/fixtures"
now="2026-09-03T10:30:00Z"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

source "$root/tests/helpers/dev-capture-environment.sh"
setup_capture_environment "$tmp_dir"
run_deployment_runtime() {
  run_deployment_fixture "$root" "$tmp_dir" "$1" "$2"
}

expect_deployment_rejected() {
  local label=$1 filter=$2 candidate
  candidate="$tmp_dir/deployment-$label.json"
  jq "$filter" "$fixtures/dev-deployment-valid.json" >"$candidate"
  if bash "$root/scripts/capture-dev-evidence.sh" deployment --validate-evidence \
    "$candidate" "$now" >/dev/null 2>&1; then
    echo "invalid Deployment evidence accepted: $label" >&2
    exit 1
  fi
}

expect_slo_rejected() {
  local label=$1 filter=$2 candidate
  candidate="$tmp_dir/slo-$label.json"
  jq "$filter" "$fixtures/dev-slo-valid.json" >"$candidate"
  if bash "$root/scripts/capture-dev-evidence.sh" slo --validate-evidence \
    "$fixtures/dev-deployment-valid.json" "$candidate" "$now" >/dev/null 2>&1; then
    echo "invalid SLO evidence accepted: $label" >&2
    exit 1
  fi
}

bash "$root/scripts/capture-dev-evidence.sh" deployment --validate-evidence \
  "$fixtures/dev-deployment-valid.json" "$now" >/dev/null
bash "$root/scripts/capture-dev-evidence.sh" slo --validate-evidence \
  "$fixtures/dev-deployment-valid.json" "$fixtures/dev-slo-valid.json" "$now" >/dev/null

# File parsing must not claim a cloud run, even when the artifact claims runtime grade.
validation_output=$(bash "$root/scripts/capture-dev-evidence.sh" deployment --validate-evidence "$fixtures/dev-deployment-valid.json" "$now")
[[ "$validation_output" == 'PASS: [STATIC]'* ]] || { echo 'schema validation claimed runtime execution' >&2; exit 1; }

# Resolve aliases before protecting the GitOps handoff path; reject ambiguous outputs.
mkdir -p "$tmp_dir/argocd-gitops/evidence/dev" "$tmp_dir/output-directory"
printf 'sentinel\n' >"$tmp_dir/argocd-gitops/evidence/dev/deployment.json"
ln -s "$tmp_dir/argocd-gitops/evidence/dev/deployment.json" "$tmp_dir/output-link"
for rejected in "$tmp_dir/output-link" "$tmp_dir/output-directory" "$tmp_dir/argocd-gitops/evidence/dev/../dev/deployment.json"; do
  if run_deployment_runtime 123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/mini-commerce "$rejected" >/dev/null 2>&1; then
    echo 'ambiguous or protected output was accepted' >&2; exit 1
  fi
done
[[ $(cat "$tmp_dir/argocd-gitops/evidence/dev/deployment.json") == sentinel ]]

# Public command injection is a hard failure, even with otherwise valid identity.
runtime_output="$tmp_dir/dev-runtime.json"
if run_deployment_runtime 123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/mini-commerce "$runtime_output" >/dev/null 2>&1; then
  echo 'public CLI fake must not generate runtime evidence' >&2; exit 1
fi
[[ ! -e "$runtime_output" ]]
[[ ! -e "$tmp_dir/cloud-called" ]]

invalid_runtime_output="$tmp_dir/deployment-invalid-runtime.json"
if run_deployment_runtime \
  123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/mini-commerce//sample-app \
  "$invalid_runtime_output" >/dev/null 2>&1; then
  echo 'invalid Deployment runtime input was accepted' >&2
  exit 1
fi
[[ ! -e "$invalid_runtime_output" ]] || {
  echo 'invalid Deployment runtime input created evidence output' >&2
  exit 1
}

sentinel_output="$tmp_dir/deployment-sentinel.json"
printf '%s\n' '{"sentinel":true}' >"$sentinel_output"
sentinel_digest=$(shasum -a 256 "$sentinel_output" | awk '{print $1}')
if run_deployment_runtime \
  123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/mini-commerce//sample-app \
  "$sentinel_output" >/dev/null 2>&1; then
  echo 'invalid Deployment runtime input was accepted over an existing output' >&2
  exit 1
fi
[[ $(shasum -a 256 "$sentinel_output" | awk '{print $1}') == "$sentinel_digest" ]] || {
  echo 'invalid Deployment runtime input replaced existing evidence output' >&2
  exit 1
}

for invalid in dev-deployment-static.json dev-deployment-unhealthy.json; do
  if bash "$root/scripts/capture-dev-evidence.sh" deployment --validate-evidence \
    "$fixtures/$invalid" "$now" >/dev/null 2>&1; then
    echo "invalid Deployment evidence accepted: $invalid" >&2
    exit 1
  fi
done

for invalid in dev-slo-static.json dev-slo-failed.json dev-slo-identity-mismatch.json dev-slo-expired.json; do
  if bash "$root/scripts/capture-dev-evidence.sh" slo --validate-evidence \
    "$fixtures/dev-deployment-valid.json" "$fixtures/$invalid" "$now" >/dev/null 2>&1; then
    echo "invalid SLO evidence accepted: $invalid" >&2
    exit 1
  fi
done

expect_deployment_rejected ecr-empty '.image.repository = ""'
expect_deployment_rejected ecr-one-character \
  '.image.repository = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/a"'
expect_deployment_rejected ecr-double-slash \
  '.image.repository = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/mini-commerce//sample-app"'
expect_deployment_rejected ecr-invalid-segment \
  '.image.repository = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/Mini-Commerce"'
expect_deployment_rejected ecr-too-long \
  '.image.repository = ("123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/" + ("a" * 257))'
expect_deployment_rejected ecr-region-mismatch \
  '.image.repository = "123456789012.dkr.ecr.us-east-1.amazonaws.com/mini-commerce"'
jq '.image.repository = "210987654321.dkr.ecr.ap-northeast-2.amazonaws.com/mini-commerce"' "$fixtures/dev-deployment-valid.json" > "$tmp_dir/network-ecr.json"
bash "$root/scripts/capture-dev-evidence.sh" deployment --validate-evidence "$tmp_dir/network-ecr.json" "$now" >/dev/null
expect_deployment_rejected cluster-trailing-path '.clusterArn += "/junk"'
expect_deployment_rejected cluster-region-mismatch \
  '.clusterArn = "arn:aws:eks:us-east-1:123456789012:cluster/dev-mini-commerce"'
expect_deployment_rejected cluster-name-101 \
  '.clusterArn = ("arn:aws:eks:ap-northeast-2:123456789012:cluster/" + ("a" * 101))'
expect_deployment_rejected observed-at-invalid-calendar '.observedAt = "2026-02-31T00:00:00Z"'

two_character_ecr="$tmp_dir/deployment-ecr-two-character.json"
jq '.image.repository = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ab"' \
  "$fixtures/dev-deployment-valid.json" >"$two_character_ecr"
bash "$root/scripts/capture-dev-evidence.sh" deployment --validate-evidence \
  "$two_character_ecr" "$now" >/dev/null

for cluster_length in 1 100; do
  cluster_name=$(printf '%*s' "$cluster_length" '' | tr ' ' a)
  cluster_arn="arn:aws:eks:ap-northeast-2:123456789012:cluster/$cluster_name"
  deployment="$tmp_dir/deployment-cluster-$cluster_length.json"
  slo="$tmp_dir/slo-cluster-$cluster_length.json"
  jq --arg arn "$cluster_arn" '.clusterArn = $arn' \
    "$fixtures/dev-deployment-valid.json" >"$deployment"
  jq --arg arn "$cluster_arn" '.clusterArn = $arn' \
    "$fixtures/dev-slo-valid.json" >"$slo"
  bash "$root/scripts/capture-dev-evidence.sh" deployment --validate-evidence \
    "$deployment" "$now" >/dev/null
  bash "$root/scripts/capture-dev-evidence.sh" slo --validate-evidence \
    "$deployment" "$slo" "$now" >/dev/null
done

expect_slo_rejected observed-at-invalid-calendar '.observedAt = "2026-02-31T00:00:00Z"'

deployment_february="$tmp_dir/deployment-february.json"
slo_invalid_expiry="$tmp_dir/slo-invalid-expiry.json"
jq '.observedAt = "2026-02-28T00:00:00Z"' \
  "$fixtures/dev-deployment-valid.json" >"$deployment_february"
jq '.observedAt = "2026-02-28T00:10:00Z" | .expiresAt = "2026-02-31T00:00:00Z"' \
  "$fixtures/dev-slo-valid.json" >"$slo_invalid_expiry"
if bash "$root/scripts/capture-dev-evidence.sh" slo --validate-evidence \
  "$deployment_february" "$slo_invalid_expiry" "2026-02-28T00:30:00Z" >/dev/null 2>&1; then
  echo 'invalid SLO evidence accepted: expires-at-invalid-calendar' >&2
  exit 1
fi

echo 'PASS: Dev evidence schema, output boundary and public fake rejection contract'
