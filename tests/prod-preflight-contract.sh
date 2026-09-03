#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/task5-fixture-helpers.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"

ready="$root/tests/fixtures/dev-ready-ap-northeast-2.json"
make_dev_handoff "$ready" "$tmp_dir/deployment.json" "$tmp_dir/slo.json"
echo network-plan >"$tmp_dir/network.tfplan"
echo eks-plan >"$tmp_dir/eks.tfplan"
render_saved_plan_summary "$root/tests/fixtures/prod-network-plan-capacity-go.json" \
  "$tmp_dir/network.tfplan" "$tmp_dir/network-plan.json" ap-northeast-2
render_saved_plan_summary "$root/tests/fixtures/prod-plan-capacity-go.json" \
  "$tmp_dir/eks.tfplan" "$tmp_dir/eks-plan.json" ap-northeast-2
jq '.mode="estimate"' "$root/tests/fixtures/capacity-go.json" >"$tmp_dir/capacity-estimate.json"

COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 AWS_REGION=ap-northeast-2 \
  bash "$root/scripts/prod-design-preflight.sh" "$tmp_dir/deployment.json" "$tmp_dir/slo.json" \
    "$ready" "$tmp_dir/network-plan.json" "$root/tests/fixtures/capacity-go.json" "$tmp_dir/design.json"

cat >"$tmp_dir/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$COURSE_FAKE_AWS_LOG"
if [[ "$*" == *"describe-instance-types"* ]]; then
  cat "$COURSE_INSTANCE_FIXTURE"
elif [[ "$*" == *"describe-subnets"* ]]; then
  jq '.subnets' "$COURSE_LIVE_FIXTURE"
else
  exit 97
fi
EOF
cat >"$tmp_dir/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
exit 98
EOF
chmod +x "$tmp_dir/bin/aws" "$tmp_dir/bin/kubectl"

COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 AWS_REGION=ap-northeast-2 AWS_PROFILE=course \
COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_FAKE_AWS_LOG="$tmp_dir/aws.log" \
COURSE_INSTANCE_FIXTURE="$root/tests/fixtures/prod-instance-capacity-go.json" \
COURSE_LIVE_FIXTURE="$root/tests/fixtures/prod-live-capacity-go.json" \
  bash "$root/scripts/prod-preflight.sh" "$tmp_dir/deployment.json" "$tmp_dir/slo.json" "$ready" \
    "$tmp_dir/design.json" "$tmp_dir/eks-plan.json" "$tmp_dir/capacity-estimate.json" "$tmp_dir/estimate.json"

jq -e '.stage == "estimate" and .decision == "GO" and .evidenceGrade == "STATIC"' \
  "$tmp_dir/estimate.json" >/dev/null
grep -Fq -- '--region ap-northeast-2' "$tmp_dir/aws.log"
if grep -Fq '[CLOUD_RUNTIME]' "$tmp_dir/estimate.json"; then
  echo 'fake AWS must not produce CLOUD_RUNTIME evidence' >&2
  exit 1
fi

jq '.expiresAt="2026-01-01T00:00:00Z"' "$tmp_dir/design.json" >"$tmp_dir/stale-design.json"
set +e
COURSE_ID=course-2026 AWS_ACCOUNT_ID=123456789012 AWS_REGION=ap-northeast-2 AWS_PROFILE=course \
COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_FAKE_AWS_LOG="$tmp_dir/stale.log" \
COURSE_INSTANCE_FIXTURE="$root/tests/fixtures/prod-instance-capacity-go.json" \
COURSE_LIVE_FIXTURE="$root/tests/fixtures/prod-live-capacity-go.json" \
  bash "$root/scripts/prod-preflight.sh" "$tmp_dir/deployment.json" "$tmp_dir/slo.json" "$ready" \
    "$tmp_dir/stale-design.json" "$tmp_dir/eks-plan.json" "$tmp_dir/capacity-estimate.json" "$tmp_dir/rejected.json" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -eq 0 || -e "$tmp_dir/rejected.json" ]]; then
  echo 'expected expired design decision to fail without output' >&2
  exit 1
fi

echo 'PASS: post-network pre-EKS Prod estimate contract'
