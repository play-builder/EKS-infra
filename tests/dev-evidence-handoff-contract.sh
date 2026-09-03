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
if [[ "$*" == *"eks describe-cluster --name dev-course --region ap-northeast-2"* ]]; then
  echo '{"cluster":{"arn":"arn:aws:eks:ap-northeast-2:123456789012:cluster/dev-course","status":"ACTIVE"}}'
else
  printf 'unexpected aws invocation: %s\n' "$*" >&2
  exit 97
fi
EOF
chmod +x "$tmp_dir/bin/kubectl" "$tmp_dir/bin/aws"

run_ch15_runtime() {
  local image_repository=$1 output=$2
  COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_CHECK_NOW="$now" AWS_PROFILE=course \
    bash "$root/scripts/course-check.sh" ch15 \
      course-dev app-dev sample-app-dev play-builder/cicd-course-sample-app \
      0123456789abcdef0123456789abcdef01234567 "$image_repository" \
      sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
      89abcdef0123456789abcdef0123456789abcdef \
      arn:aws:eks:ap-northeast-2:123456789012:cluster/dev-course ap-northeast-2 \
      --output "$output"
}

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

runtime_output="$tmp_dir/ch15-runtime.json"
run_ch15_runtime \
  123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/course/sample-app \
  "$runtime_output" >/dev/null
jq -e '
  .schemaVersion == "course.dev-deployment/v1" and
  .evidenceGrade == "STATIC" and
  .status == {sync:"Synced",health:"Healthy"}
' "$runtime_output" >/dev/null

invalid_runtime_output="$tmp_dir/ch15-invalid-runtime.json"
if run_ch15_runtime \
  123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/course//sample-app \
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
  123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/course//sample-app \
  "$sentinel_output" >/dev/null 2>&1; then
  echo 'invalid Ch15 runtime input was accepted over an existing output' >&2
  exit 1
fi
[[ $(shasum -a 256 "$sentinel_output" | awk '{print $1}') == "$sentinel_digest" ]] || {
  echo 'invalid Ch15 runtime input replaced existing evidence output' >&2
  exit 1
}

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
expect_ch15_rejected ecr-one-character \
  '.image.repository = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/a"'
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

two_character_ecr="$tmp_dir/ch15-ecr-two-character.json"
jq '.image.repository = "123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/ab"' \
  "$fixtures/dev-deployment-valid.json" >"$two_character_ecr"
bash "$root/scripts/course-check.sh" ch15 --validate-evidence \
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
