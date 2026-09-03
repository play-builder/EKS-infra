#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixtures="$root/tests/fixtures"
now="2026-09-03T10:30:00Z"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

expect_ch15_rejected() {
  local label=$1 filter=$2 candidate
  candidate="$tmp_dir/ch15-$label.json"
  jq "$filter" "$fixtures/dev-deployment-valid.json" >"$candidate"
  if bash "$root/scripts/course-check.sh" ch15 --validate-evidence \
    "$candidate" "$now" >/dev/null 2>&1; then
    echo "invalid Ch15 evidence accepted: $label" >&2
    exit 1
  fi
}

expect_ch16_rejected() {
  local label=$1 filter=$2 candidate
  candidate="$tmp_dir/ch16-$label.json"
  jq "$filter" "$fixtures/dev-slo-valid.json" >"$candidate"
  if bash "$root/scripts/course-check.sh" ch16 --validate-evidence \
    "$fixtures/dev-deployment-valid.json" "$candidate" "$now" >/dev/null 2>&1; then
    echo "invalid Ch16 evidence accepted: $label" >&2
    exit 1
  fi
}

bash "$root/scripts/course-check.sh" ch15 --validate-evidence \
  "$fixtures/dev-deployment-valid.json" "$now" >/dev/null
bash "$root/scripts/course-check.sh" ch16 --validate-evidence \
  "$fixtures/dev-deployment-valid.json" "$fixtures/dev-slo-valid.json" "$now" >/dev/null

for invalid in dev-deployment-static.json dev-deployment-unhealthy.json; do
  if bash "$root/scripts/course-check.sh" ch15 --validate-evidence \
    "$fixtures/$invalid" "$now" >/dev/null 2>&1; then
    echo "invalid Ch15 evidence accepted: $invalid" >&2
    exit 1
  fi
done

for invalid in dev-slo-static.json dev-slo-failed.json dev-slo-identity-mismatch.json dev-slo-expired.json; do
  if bash "$root/scripts/course-check.sh" ch16 --validate-evidence \
    "$fixtures/dev-deployment-valid.json" "$fixtures/$invalid" "$now" >/dev/null 2>&1; then
    echo "invalid Ch16 evidence accepted: $invalid" >&2
    exit 1
  fi
done

expect_ch15_rejected ecr-empty '.image.repository = ""'
expect_ch15_rejected ecr-double-slash \
  '.image.repository = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/course//sample-app"'
expect_ch15_rejected ecr-invalid-segment \
  '.image.repository = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/Course/sample-app"'
expect_ch15_rejected ecr-too-long \
  '.image.repository = ("123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/" + ("a" * 257))'
expect_ch15_rejected ecr-region-mismatch \
  '.image.repository = "123456789012.dkr.ecr.us-east-1.amazonaws.com/course/sample-app"'
expect_ch15_rejected ecr-account-mismatch \
  '.image.repository = "210987654321.dkr.ecr.ap-northeast-2.amazonaws.com/course/sample-app"'
expect_ch15_rejected cluster-trailing-path '.clusterArn += "/junk"'
expect_ch15_rejected cluster-region-mismatch \
  '.clusterArn = "arn:aws:eks:us-east-1:123456789012:cluster/dev-course"'
expect_ch15_rejected cluster-name-101 \
  '.clusterArn = ("arn:aws:eks:ap-northeast-2:123456789012:cluster/" + ("a" * 101))'
expect_ch15_rejected observed-at-invalid-calendar '.observedAt = "2026-02-31T00:00:00Z"'

for cluster_length in 1 100; do
  cluster_name=$(printf '%*s' "$cluster_length" '' | tr ' ' a)
  cluster_arn="arn:aws:eks:ap-northeast-2:123456789012:cluster/$cluster_name"
  deployment="$tmp_dir/ch15-cluster-$cluster_length.json"
  slo="$tmp_dir/ch16-cluster-$cluster_length.json"
  jq --arg arn "$cluster_arn" '.clusterArn = $arn' \
    "$fixtures/dev-deployment-valid.json" >"$deployment"
  jq --arg arn "$cluster_arn" '.clusterArn = $arn' \
    "$fixtures/dev-slo-valid.json" >"$slo"
  bash "$root/scripts/course-check.sh" ch15 --validate-evidence \
    "$deployment" "$now" >/dev/null
  bash "$root/scripts/course-check.sh" ch16 --validate-evidence \
    "$deployment" "$slo" "$now" >/dev/null
done

expect_ch16_rejected observed-at-invalid-calendar '.observedAt = "2026-02-31T00:00:00Z"'

deployment_february="$tmp_dir/ch15-february.json"
slo_invalid_expiry="$tmp_dir/ch16-invalid-expiry.json"
jq '.observedAt = "2026-02-28T00:00:00Z"' \
  "$fixtures/dev-deployment-valid.json" >"$deployment_february"
jq '.observedAt = "2026-02-28T00:10:00Z" | .expiresAt = "2026-02-31T00:00:00Z"' \
  "$fixtures/dev-slo-valid.json" >"$slo_invalid_expiry"
if bash "$root/scripts/course-check.sh" ch16 --validate-evidence \
  "$deployment_february" "$slo_invalid_expiry" "2026-02-28T00:30:00Z" >/dev/null 2>&1; then
  echo 'invalid Ch16 evidence accepted: expires-at-invalid-calendar' >&2
  exit 1
fi

echo 'PASS: Ch15/Ch16 runtime evidence handoff contract'
