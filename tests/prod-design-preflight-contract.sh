#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/task5-fixture-helpers.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

ready="$root/tests/fixtures/dev-ready-ap-northeast-2.json"
make_dev_handoff "$ready" "$tmp_dir/deployment.json" "$tmp_dir/slo.json"
echo 'saved terraform network plan bytes' >"$tmp_dir/network.tfplan"
render_saved_plan_summary "$root/tests/fixtures/prod-network-plan-capacity-go.json" \
  "$tmp_dir/network.tfplan" "$tmp_dir/network-plan.json" ap-northeast-2

COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 AWS_REGION=ap-northeast-2 \
  bash "$root/scripts/prod-design-preflight.sh" "$tmp_dir/deployment.json" "$tmp_dir/slo.json" \
    "$ready" "$tmp_dir/network-plan.json" "$root/tests/fixtures/capacity-go.json" "$tmp_dir/design.json"
jq -e '
  keys == ["accountId","bindings","courseId","decision","evidenceGrade","expiresAt","issuedAt","region","schemaVersion","stage"] and
  .schemaVersion == "course.prod-preflight/v1" and .stage == "design" and
  .evidenceGrade == "STATIC" and .decision == "GO" and
  (.bindings | keys == ["capacityInputSha256","devDeploymentSha256","devReadySha256","devSloSha256","previousDecisionSha256","savedPlanSha256"])
' "$tmp_dir/design.json" >/dev/null

expect_network_timestamp_rejected() {
  local label=$1 field=$2 value=$3
  local candidate="$tmp_dir/network-$label.json"
  local rejected="$tmp_dir/rejected-$label.json"
  jq --arg field "$field" --arg value "$value" '.[$field]=$value' "$tmp_dir/network-plan.json" >"$candidate"
  if COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 AWS_REGION=ap-northeast-2 \
    bash "$root/scripts/prod-design-preflight.sh" "$tmp_dir/deployment.json" "$tmp_dir/slo.json" \
      "$ready" "$candidate" "$root/tests/fixtures/capacity-go.json" "$rejected" >/dev/null 2>&1; then
    echo "expected $label network-plan timestamp to fail" >&2
    exit 1
  fi
  [[ ! -e "$rejected" ]] || { echo "invalid $label timestamp must not produce evidence" >&2; exit 1; }
}

expect_network_timestamp_rejected observed-invalid-calendar observedAt '2020-02-30T00:00:00Z'
expect_network_timestamp_rejected expires-invalid-calendar expiresAt '2099-02-31T00:00:00Z'

jq '.savedPlan.sha256="sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
  "$tmp_dir/network-plan.json" >"$tmp_dir/bad-plan.json"
set +e
COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 AWS_REGION=ap-northeast-2 \
  bash "$root/scripts/prod-design-preflight.sh" "$tmp_dir/deployment.json" "$tmp_dir/slo.json" \
    "$ready" "$tmp_dir/bad-plan.json" "$root/tests/fixtures/capacity-go.json" "$tmp_dir/rejected.json" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -eq 0 || -e "$tmp_dir/rejected.json" ]]; then
  echo 'expected digest-mismatched network plan to fail without output' >&2
  exit 1
fi

echo 'PASS: pre-network Prod design preflight contract'
