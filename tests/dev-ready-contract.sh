#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/task5-fixture-helpers.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

for region in ap-northeast-2 us-east-1; do
  ready="$root/tests/fixtures/dev-ready-$region.json"
  deployment="$tmp_dir/deployment-$region.json"
  slo="$tmp_dir/slo-$region.json"
  make_dev_handoff "$ready" "$deployment" "$slo"
  output=$(AWS_REGION="$region" AWS_ACCOUNT_ID=123456789012 \
    bash "$root/scripts/dev-ready-check.sh" "$deployment" "$slo" "$ready")
  grep -Fq 'PASS: [STATIC]' <<<"$output"
  ! grep -Fq '[CLOUD_RUNTIME]' <<<"$output"
done

one_character_ready="$tmp_dir/dev-ready-one-character-cluster.json"
one_character_deployment="$tmp_dir/deployment-one-character-cluster.json"
one_character_slo="$tmp_dir/slo-one-character-cluster.json"
jq '.cluster.arn="arn:aws:eks:ap-northeast-2:123456789012:cluster/a"' \
  "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$one_character_ready"
make_dev_handoff "$one_character_ready" "$one_character_deployment" "$one_character_slo"
AWS_REGION=ap-northeast-2 AWS_ACCOUNT_ID=123456789012 \
  bash "$root/scripts/dev-ready-check.sh" \
    "$one_character_deployment" "$one_character_slo" "$one_character_ready" >/dev/null

deployment="$tmp_dir/deployment-invalid.json"
slo="$tmp_dir/slo-invalid.json"
make_dev_handoff "$root/tests/fixtures/dev-ready-ap-northeast-2.json" "$deployment" "$slo"
jq '.unexpected=true' "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$tmp_dir/dev-ready-extra.json"
jq '.evidenceGrade="STATIC"' "$deployment" >"$tmp_dir/static-deployment.json"
jq '.image.indexDigest="sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"' \
  "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$tmp_dir/dev-ready-mismatch.json"
jq '.workflow.name="Build and publish"' \
  "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$tmp_dir/dev-ready-wrong-workflow.json"
jq '.workflow.event="workflow_dispatch"' \
  "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$tmp_dir/dev-ready-wrong-event.json"
jq '.workflow.runUrl="https://github.com/play-builder/cicd-course-sample-app/actions/runs/999"' \
  "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$tmp_dir/dev-ready-wrong-run-url.json"
jq '.workflow.runUrl="https://github.com/other-owner/cicd-course-sample-app/actions/runs/101"' \
  "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$tmp_dir/dev-ready-wrong-workflow-repository.json"
jq '.workflow.runId=101' \
  "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$tmp_dir/dev-ready-numeric-run-id.json"
jq '.workflow.runId="not-digits"' \
  "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$tmp_dir/dev-ready-nondigit-run-id.json"
jq '.workflow.runAttempt=0' \
  "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$tmp_dir/dev-ready-zero-run-attempt.json"
jq '.image.platforms=["linux/amd64"]' \
  "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$tmp_dir/dev-ready-missing-arm64.json"
jq '.attestation.githubUrl="https://github.com/play-builder/cicd-course-sample-app/attestations/other-id"' \
  "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$tmp_dir/dev-ready-wrong-attestation-id.json"
jq '.attestation.githubUrl="https://github.com/other-owner/cicd-course-sample-app/attestations/101"' \
  "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$tmp_dir/dev-ready-wrong-attestation-repository.json"
jq '.attestation.githubId=""' \
  "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$tmp_dir/dev-ready-empty-attestation-id.json"
jq '
  .attestation.githubId="alpha" |
  .attestation.githubUrl="https://github.com/play-builder/cicd-course-sample-app/attestations/alpha"
' "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$tmp_dir/dev-ready-nondigit-attestation-id.json"
jq '.source.repository="attacker/cicd-course-sample-app"' \
  "$deployment" >"$tmp_dir/deployment-wrong-source-repository.json"
jq '.source.repository="attacker/cicd-course-sample-app"' \
  "$slo" >"$tmp_dir/slo-wrong-source-repository.json"
jq '.image.repository="123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/"' \
  "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$tmp_dir/dev-ready-registry-root-only.json"
make_dev_handoff "$tmp_dir/dev-ready-registry-root-only.json" \
  "$tmp_dir/deployment-registry-root-only.json" "$tmp_dir/slo-registry-root-only.json"
jq '.image.repository="not-an-ecr-repository"' \
  "$deployment" >"$tmp_dir/deployment-invalid-image-repository.json"
jq '.image.repository="not-an-ecr-repository"' \
  "$slo" >"$tmp_dir/slo-invalid-image-repository.json"
ecr_prefix='123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/'
long_repository_name=$(printf 'a%.0s' {1..257})
invalid_repositories=(
  "${ecr_prefix}course//sample-app"
  "${ecr_prefix}course/-sample-app"
  "${ecr_prefix}${long_repository_name}"
)
for index in "${!invalid_repositories[@]}"; do
  jq --arg repository "${invalid_repositories[$index]}" '.image.repository=$repository' \
    "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$tmp_dir/dev-ready-invalid-ecr-$index.json"
  make_dev_handoff "$tmp_dir/dev-ready-invalid-ecr-$index.json" \
    "$tmp_dir/deployment-invalid-ecr-$index.json" "$tmp_dir/slo-invalid-ecr-$index.json"
done
jq '.observedAt="2026-02-31T00:00:00Z"' \
  "$deployment" >"$tmp_dir/deployment-invalid-calendar-date.json"
jq '.observedAt="2026-02-31T00:00:00Z"' \
  "$slo" >"$tmp_dir/slo-invalid-calendar-date.json"
jq '.issuedAt="2026-02-31T00:00:00Z"' \
  "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$tmp_dir/dev-ready-invalid-calendar-date.json"
jq '.expiresAt="2099-02-31T01:00:00Z"' \
  "$slo" >"$tmp_dir/slo-invalid-expiry-date.json"
jq '.expiresAt="2099-02-31T01:00:00Z"' \
  "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$tmp_dir/dev-ready-invalid-expiry-date.json"
long_cluster_name=$(printf 'a%.0s' {1..101})
jq --arg name "$long_cluster_name" \
  '.cluster.arn="arn:aws:eks:ap-northeast-2:123456789012:cluster/"+$name' \
  "$root/tests/fixtures/dev-ready-ap-northeast-2.json" >"$tmp_dir/dev-ready-long-cluster-name.json"
make_dev_handoff "$tmp_dir/dev-ready-long-cluster-name.json" \
  "$tmp_dir/deployment-long-cluster-name.json" "$tmp_dir/slo-long-cluster-name.json"

run_rejected() {
  local deployment_file=$1 ready_file=$2 status
  set +e
  AWS_REGION=ap-northeast-2 AWS_ACCOUNT_ID=123456789012 bash "$root/scripts/dev-ready-check.sh" \
    "$deployment_file" "$slo" "$ready_file" >/dev/null 2>&1
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    echo "expected DEV_READY rejection: $ready_file" >&2
    exit 1
  fi
}

run_rejected_with_slo() {
  local deployment_file=$1 slo_file=$2 ready_file=$3 status
  set +e
  AWS_REGION=ap-northeast-2 AWS_ACCOUNT_ID=123456789012 bash "$root/scripts/dev-ready-check.sh" \
    "$deployment_file" "$slo_file" "$ready_file" >/dev/null 2>&1
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    echo "expected DEV_READY rejection: $ready_file" >&2
    exit 1
  fi
}

run_rejected "$deployment" "$root/tests/fixtures/dev-ready-invalid-aliases.json"
run_rejected "$deployment" "$tmp_dir/dev-ready-extra.json"
run_rejected "$tmp_dir/static-deployment.json" "$root/tests/fixtures/dev-ready-ap-northeast-2.json"
run_rejected "$deployment" "$tmp_dir/dev-ready-mismatch.json"
run_rejected "$deployment" "$tmp_dir/dev-ready-wrong-workflow.json"
run_rejected "$deployment" "$tmp_dir/dev-ready-wrong-event.json"
run_rejected "$deployment" "$tmp_dir/dev-ready-wrong-run-url.json"
run_rejected "$deployment" "$tmp_dir/dev-ready-wrong-workflow-repository.json"
run_rejected "$deployment" "$tmp_dir/dev-ready-numeric-run-id.json"
run_rejected "$deployment" "$tmp_dir/dev-ready-nondigit-run-id.json"
run_rejected "$deployment" "$tmp_dir/dev-ready-zero-run-attempt.json"
run_rejected "$deployment" "$tmp_dir/dev-ready-missing-arm64.json"
run_rejected "$deployment" "$tmp_dir/dev-ready-wrong-attestation-id.json"
run_rejected "$deployment" "$tmp_dir/dev-ready-wrong-attestation-repository.json"
run_rejected "$deployment" "$tmp_dir/dev-ready-empty-attestation-id.json"
run_rejected "$deployment" "$tmp_dir/dev-ready-nondigit-attestation-id.json"
run_rejected_with_slo "$tmp_dir/deployment-wrong-source-repository.json" \
  "$tmp_dir/slo-wrong-source-repository.json" "$root/tests/fixtures/dev-ready-ap-northeast-2.json"
run_rejected_with_slo "$tmp_dir/deployment-registry-root-only.json" \
  "$tmp_dir/slo-registry-root-only.json" "$tmp_dir/dev-ready-registry-root-only.json"
run_rejected_with_slo "$tmp_dir/deployment-invalid-image-repository.json" \
  "$slo" "$root/tests/fixtures/dev-ready-ap-northeast-2.json"
run_rejected_with_slo "$deployment" "$tmp_dir/slo-invalid-image-repository.json" \
  "$root/tests/fixtures/dev-ready-ap-northeast-2.json"
for index in "${!invalid_repositories[@]}"; do
  run_rejected_with_slo "$tmp_dir/deployment-invalid-ecr-$index.json" \
    "$tmp_dir/slo-invalid-ecr-$index.json" "$tmp_dir/dev-ready-invalid-ecr-$index.json"
done
run_rejected_with_slo "$tmp_dir/deployment-invalid-calendar-date.json" \
  "$slo" "$root/tests/fixtures/dev-ready-ap-northeast-2.json"
run_rejected_with_slo "$deployment" "$tmp_dir/slo-invalid-calendar-date.json" \
  "$tmp_dir/dev-ready-invalid-calendar-date.json"
run_rejected_with_slo "$deployment" "$tmp_dir/slo-invalid-expiry-date.json" \
  "$tmp_dir/dev-ready-invalid-expiry-date.json"
run_rejected_with_slo "$tmp_dir/deployment-long-cluster-name.json" \
  "$tmp_dir/slo-long-cluster-name.json" "$tmp_dir/dev-ready-long-cluster-name.json"

grep -Fq '"name": "ci"' "$root/README.md"
grep -Fq '"event": "push"' "$root/README.md"
grep -Fq '"runId": "<digits>"' "$root/README.md"
grep -Fq 'linux/amd64' "$root/README.md"
grep -Fq 'linux/arm64' "$root/README.md"
grep -Fq '"githubId": "<digits>"' "$root/README.md"
grep -Fq 'attestations/<digits>' "$root/README.md"
! grep -Fq 'Build and publish' "$root/README.md"
grep -Fq '"name": "ci"' "$root/docs/architecture.md"
grep -Fq '"githubId": "<digits>"' "$root/docs/architecture.md"
grep -Fq 'attestations/<digits>' "$root/docs/architecture.md"
! grep -Fq 'Build and publish' "$root/docs/architecture.md"

echo 'PASS: canonical DEV_READY and intermediate evidence contract'
