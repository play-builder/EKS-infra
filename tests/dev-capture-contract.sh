#!/usr/bin/env bash
set -Eeuo pipefail
(
#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/helpers/dev-capture-environment.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
setup_capture_environment "$tmp_dir"

output=$(run_slo_fixture "$root" "$tmp_dir" "$tmp_dir/slo.json")
grep -Fq '[STATIC] SIMULATED_CLOUD_CONTRACT' <<<"$output"
jq -e '.evidenceGrade == "STATIC" and .status == "PASS"' "$tmp_dir/slo.json" >/dev/null

jq . "$tmp_dir/alert-delivery.json" >"$tmp_dir/alert-delivery-valid.json"
export PLATFORM_FAKE_CLOUD_LOG="$tmp_dir/invalid-timestamp-cloud.log"
for timestamp_case in \
  'invalid-calendar|2020-02-30T00:00:00Z' \
  'fractional|2020-03-01T00:00:00.123Z' \
  'offset|2020-03-01T09:00:00+09:00' \
  'future|2026-09-03T10:31:00Z'; do
  IFS='|' read -r label value <<<"$timestamp_case"
  : >"$PLATFORM_FAKE_CLOUD_LOG"
  jq --arg value "$value" '.observedAt=$value' "$tmp_dir/alert-delivery-valid.json" >"$tmp_dir/alert-delivery.json"
  if run_slo_fixture "$root" "$tmp_dir" "$tmp_dir/invalid-$label.json" >/dev/null 2>&1; then
    echo "alert delivery $label observedAt must be rejected" >&2
    exit 1
  fi
  [[ ! -e "$tmp_dir/invalid-$label.json" ]]
  [[ ! -s "$PLATFORM_FAKE_CLOUD_LOG" ]] || {
    echo "alert delivery $label observedAt must fail before cloud queries" >&2
    exit 1
  }
done
unset PLATFORM_FAKE_CLOUD_LOG
jq . "$tmp_dir/alert-delivery-valid.json" >"$tmp_dir/alert-delivery.json"

if FAKE_SNS_PENDING=true run_slo_fixture "$root" "$tmp_dir" "$tmp_dir/pending.json" >/dev/null 2>&1; then
  echo 'PendingConfirmation must be routing-only evidence, not delivery proof' >&2
  exit 1
fi
[[ ! -e "$tmp_dir/pending.json" ]]

if FAKE_SNS_WRONG_SOURCE=true run_slo_fixture "$root" "$tmp_dir" "$tmp_dir/wrong-source.json" >/dev/null 2>&1; then
  echo 'SNS policy for another AMP workspace/account must not prove delivery authorization' >&2
  exit 1
fi
[[ ! -e "$tmp_dir/wrong-source.json" ]]

jq '.resolved.delivered=false' "$tmp_dir/alert-delivery.json" >"$tmp_dir/incomplete-delivery.json"
mv "$tmp_dir/incomplete-delivery.json" "$tmp_dir/alert-delivery.json"
if run_slo_fixture "$root" "$tmp_dir" "$tmp_dir/incomplete.json" >/dev/null 2>&1; then
  echo 'Firing-only evidence must not prove resolved delivery' >&2
  exit 1
fi

echo 'PASS: AMP alerting requires active definitions, confirmed SNS, and Firing/Resolved delivery'

)
(
#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/helpers/dev-capture-environment.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
setup_capture_environment "$tmp_dir"

run_slo_fixture "$root" "$tmp_dir" "$tmp_dir/slo.json" >/dev/null

if FAKE_K6_BAD=true run_slo_fixture "$root" "$tmp_dir" "$tmp_dir/unbounded.json" >/dev/null 2>&1; then
  echo 'k6 evidence without an explicit compute-cost boundary must fail' >&2
  exit 1
fi
[[ ! -e "$tmp_dir/unbounded.json" ]]

echo 'PASS: Ch16 k6 controller and run carry readiness, duration, rate, and cost boundaries'

)

(
#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixtures="$root/tests/fixtures"
now="2026-09-03T10:30:00Z"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$*" == *"get application sample-app-dev"* ]]; then
  echo '{"status":{"sync":{"status":"Synced","revision":"89abcdef0123456789abcdef0123456789abcdef"},"health":{"status":"Healthy"}}}'
else
  printf 'unexpected kubectl invocation: %s\n' "$*" >&2
  exit 97
fi
EOF
cat >"$tmp_dir/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$*" == *"eks describe-cluster --name dev-mini-commerce --region ap-northeast-2"* ]]; then
  echo '{"cluster":{"arn":"arn:aws:eks:ap-northeast-2:123456789012:cluster/dev-mini-commerce","status":"ACTIVE"}}'
else
  printf 'unexpected aws invocation: %s\n' "$*" >&2
  exit 97
fi
EOF
chmod +x "$tmp_dir/bin/kubectl" "$tmp_dir/bin/aws"

run_ch15_runtime() {
  local image_repository=$1 output=$2
  PLATFORM_CHECK_BIN_DIR="$tmp_dir/bin" PLATFORM_CHECK_NOW="$now" AWS_PROFILE=mini-commerce \
    bash "$root/scripts/capture-dev-evidence.sh" deployment \
      mini-commerce-dev app-dev sample-app-dev play-builder/mini-commerce \
      0123456789abcdef0123456789abcdef01234567 "$image_repository" \
      sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
      89abcdef0123456789abcdef0123456789abcdef \
      arn:aws:eks:ap-northeast-2:123456789012:cluster/dev-mini-commerce ap-northeast-2 \
      --output "$output"
}

expect_ch15_rejected() {
  local label=$1 filter=$2 candidate
  candidate="$tmp_dir/ch15-$label.json"
  jq "$filter" "$fixtures/dev-deployment-valid.json" >"$candidate"
  if bash "$root/scripts/capture-dev-evidence.sh" deployment --validate-evidence \
    "$candidate" "$now" >/dev/null 2>&1; then
    echo "invalid Ch15 evidence accepted: $label" >&2
    exit 1
  fi
}

expect_ch16_rejected() {
  local label=$1 filter=$2 candidate
  candidate="$tmp_dir/ch16-$label.json"
  jq "$filter" "$fixtures/dev-slo-valid.json" >"$candidate"
  if bash "$root/scripts/capture-dev-evidence.sh" slo --validate-evidence \
    "$fixtures/dev-deployment-valid.json" "$candidate" "$now" >/dev/null 2>&1; then
    echo "invalid Ch16 evidence accepted: $label" >&2
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
  if run_ch15_runtime 123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/mini-commerce "$rejected" >/dev/null 2>&1; then
    echo 'ambiguous or protected output was accepted' >&2; exit 1
  fi
done
[[ $(cat "$tmp_dir/argocd-gitops/evidence/dev/deployment.json") == sentinel ]]

runtime_output="$tmp_dir/ch15-runtime.json"
run_ch15_runtime \
  123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/mini-commerce \
  "$runtime_output" >/dev/null
jq -e '
  .schemaVersion == "playbuilder.dev-deployment/v1" and
  .evidenceGrade == "STATIC" and
  .status == {sync:"Synced",health:"Healthy"}
' "$runtime_output" >/dev/null

invalid_runtime_output="$tmp_dir/ch15-invalid-runtime.json"
if run_ch15_runtime \
  123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/mini-commerce//sample-app \
  "$invalid_runtime_output" >/dev/null 2>&1; then
  echo 'invalid Ch15 runtime input was accepted' >&2
  exit 1
fi
[[ ! -e "$invalid_runtime_output" ]] || {
  echo 'invalid Ch15 runtime input created evidence output' >&2
  exit 1
}

sentinel_output="$tmp_dir/ch15-sentinel.json"
printf '%s\n' '{"sentinel":true}' >"$sentinel_output"
sentinel_digest=$(shasum -a 256 "$sentinel_output" | awk '{print $1}')
if run_ch15_runtime \
  123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/mini-commerce//sample-app \
  "$sentinel_output" >/dev/null 2>&1; then
  echo 'invalid Ch15 runtime input was accepted over an existing output' >&2
  exit 1
fi
[[ $(shasum -a 256 "$sentinel_output" | awk '{print $1}') == "$sentinel_digest" ]] || {
  echo 'invalid Ch15 runtime input replaced existing evidence output' >&2
  exit 1
}

for invalid in dev-deployment-static.json dev-deployment-unhealthy.json; do
  if bash "$root/scripts/capture-dev-evidence.sh" deployment --validate-evidence \
    "$fixtures/$invalid" "$now" >/dev/null 2>&1; then
    echo "invalid Ch15 evidence accepted: $invalid" >&2
    exit 1
  fi
done

for invalid in dev-slo-static.json dev-slo-failed.json dev-slo-identity-mismatch.json dev-slo-expired.json; do
  if bash "$root/scripts/capture-dev-evidence.sh" slo --validate-evidence \
    "$fixtures/dev-deployment-valid.json" "$fixtures/$invalid" "$now" >/dev/null 2>&1; then
    echo "invalid Ch16 evidence accepted: $invalid" >&2
    exit 1
  fi
done

expect_ch15_rejected ecr-empty '.image.repository = ""'
expect_ch15_rejected ecr-one-character \
  '.image.repository = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/a"'
expect_ch15_rejected ecr-double-slash \
  '.image.repository = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/mini-commerce//sample-app"'
expect_ch15_rejected ecr-invalid-segment \
  '.image.repository = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/Mini-Commerce"'
expect_ch15_rejected ecr-too-long \
  '.image.repository = ("123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/" + ("a" * 257))'
expect_ch15_rejected ecr-region-mismatch \
  '.image.repository = "123456789012.dkr.ecr.us-east-1.amazonaws.com/mini-commerce"'
expect_ch15_rejected ecr-account-mismatch \
  '.image.repository = "210987654321.dkr.ecr.ap-northeast-2.amazonaws.com/mini-commerce"'
expect_ch15_rejected cluster-trailing-path '.clusterArn += "/junk"'
expect_ch15_rejected cluster-region-mismatch \
  '.clusterArn = "arn:aws:eks:us-east-1:123456789012:cluster/dev-mini-commerce"'
expect_ch15_rejected cluster-name-101 \
  '.clusterArn = ("arn:aws:eks:ap-northeast-2:123456789012:cluster/" + ("a" * 101))'
expect_ch15_rejected observed-at-invalid-calendar '.observedAt = "2026-02-31T00:00:00Z"'

two_character_ecr="$tmp_dir/ch15-ecr-two-character.json"
jq '.image.repository = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ab"' \
  "$fixtures/dev-deployment-valid.json" >"$two_character_ecr"
bash "$root/scripts/capture-dev-evidence.sh" deployment --validate-evidence \
  "$two_character_ecr" "$now" >/dev/null

for cluster_length in 1 100; do
  cluster_name=$(printf '%*s' "$cluster_length" '' | tr ' ' a)
  cluster_arn="arn:aws:eks:ap-northeast-2:123456789012:cluster/$cluster_name"
  deployment="$tmp_dir/ch15-cluster-$cluster_length.json"
  slo="$tmp_dir/ch16-cluster-$cluster_length.json"
  jq --arg arn "$cluster_arn" '.clusterArn = $arn' \
    "$fixtures/dev-deployment-valid.json" >"$deployment"
  jq --arg arn "$cluster_arn" '.clusterArn = $arn' \
    "$fixtures/dev-slo-valid.json" >"$slo"
  bash "$root/scripts/capture-dev-evidence.sh" deployment --validate-evidence \
    "$deployment" "$now" >/dev/null
  bash "$root/scripts/capture-dev-evidence.sh" slo --validate-evidence \
    "$deployment" "$slo" "$now" >/dev/null
done

expect_ch16_rejected observed-at-invalid-calendar '.observedAt = "2026-02-31T00:00:00Z"'

deployment_february="$tmp_dir/ch15-february.json"
slo_invalid_expiry="$tmp_dir/ch16-invalid-expiry.json"
jq '.observedAt = "2026-02-28T00:00:00Z"' \
  "$fixtures/dev-deployment-valid.json" >"$deployment_february"
jq '.observedAt = "2026-02-28T00:10:00Z" | .expiresAt = "2026-02-31T00:00:00Z"' \
  "$fixtures/dev-slo-valid.json" >"$slo_invalid_expiry"
if bash "$root/scripts/capture-dev-evidence.sh" slo --validate-evidence \
  "$deployment_february" "$slo_invalid_expiry" "2026-02-28T00:30:00Z" >/dev/null 2>&1; then
  echo 'invalid Ch16 evidence accepted: expires-at-invalid-calendar' >&2
  exit 1
fi

echo 'PASS: Ch15/Ch16 runtime evidence handoff contract'

)
