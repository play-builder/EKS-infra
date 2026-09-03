#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"

cat >"$tmp_dir/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$COURSE_FAKE_KUBECTL_LOG"
if [[ "$*" == *"get nodes"* ]]; then
  jq '.nodes' "$COURSE_LIVE_FIXTURE"
elif [[ "$*" == *"get daemonsets"* ]]; then
  jq '.daemonSets' "$COURSE_LIVE_FIXTURE"
else
  exit 97
fi
EOF
cat >"$tmp_dir/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$COURSE_FAKE_AWS_LOG"
jq '.subnets' "$COURSE_LIVE_FIXTURE"
EOF
chmod +x "$tmp_dir/bin/kubectl" "$tmp_dir/bin/aws"

for region in ap-northeast-2 us-east-1; do
  jq --arg region "$region" '
    .profile.region=$region |
    .profile.clusterArn=("arn:aws:eks:"+$region+":123456789012:cluster/prod-playdevops-eks")
  ' "$root/tests/fixtures/prod-live-capacity-go.json" >"$tmp_dir/live-$region.json"
  jq '.profile' "$tmp_dir/live-$region.json" >"$tmp_dir/profile-$region.json"
  COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_LIVE_FIXTURE="$tmp_dir/live-$region.json" \
  COURSE_FAKE_AWS_LOG="$tmp_dir/aws-$region.log" COURSE_FAKE_KUBECTL_LOG="$tmp_dir/kube-$region.log" \
  AWS_PROFILE=course AWS_REGION="$region" \
    bash "$root/scripts/prod-live-capacity-check.sh" course-prod "$tmp_dir/profile-$region.json" \
      "$tmp_dir/result-$region.json"
  jq -e '.decision == "GO" and .evidenceGrade == "STATIC" and .region == $region' \
    --arg region "$region" "$tmp_dir/result-$region.json" >/dev/null
  grep -Fq -- "--region $region" "$tmp_dir/aws-$region.log"
  grep -Fq -- '--context course-prod' "$tmp_dir/kube-$region.log"
done

! grep -R -Fq '[CLOUD_RUNTIME]' "$tmp_dir"/result-*.json

run_cluster_boundary() {
  local label=$1 cluster_arn=$2 expectation=$3 status
  local live="$tmp_dir/cluster-$label-live.json"
  local profile="$tmp_dir/cluster-$label-profile.json"
  local result="$tmp_dir/cluster-$label-result.json"
  jq --arg arn "$cluster_arn" '.profile.clusterArn = $arn' \
    "$root/tests/fixtures/prod-live-capacity-go.json" >"$live"
  jq '.profile' "$live" >"$profile"
  set +e
  COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_LIVE_FIXTURE="$live" \
  COURSE_FAKE_AWS_LOG="$tmp_dir/cluster-$label-aws.log" \
  COURSE_FAKE_KUBECTL_LOG="$tmp_dir/cluster-$label-kube.log" \
  AWS_PROFILE=course AWS_REGION=ap-northeast-2 \
    bash "$root/scripts/prod-live-capacity-check.sh" course-prod "$profile" "$result" >/dev/null 2>&1
  status=$?
  set -e
  if [[ "$expectation" == accept ]]; then
    [[ "$status" -eq 0 && -f "$result" ]] || { echo "expected cluster ARN acceptance: $label" >&2; exit 1; }
  elif [[ "$status" -eq 0 || -e "$result" ]]; then
    echo "expected cluster ARN rejection without output: $label" >&2
    exit 1
  fi
}

for cluster_length in 1 100; do
  cluster_name=$(printf '%*s' "$cluster_length" '' | tr ' ' a)
  run_cluster_boundary "name-$cluster_length" \
    "arn:aws:eks:ap-northeast-2:123456789012:cluster/$cluster_name" accept
done
run_cluster_boundary name-101 \
  "arn:aws:eks:ap-northeast-2:123456789012:cluster/$(printf '%*s' 101 '' | tr ' ' a)" reject
run_cluster_boundary trailing-path \
  'arn:aws:eks:ap-northeast-2:123456789012:cluster/prod-playdevops-eks/junk' reject

jq '.subnets.Subnets[].AvailableIpAddressCount=0' "$root/tests/fixtures/prod-live-capacity-go.json" >"$tmp_dir/live-no-ip.json"
jq '.profile' "$tmp_dir/live-no-ip.json" >"$tmp_dir/profile-no-ip.json"
set +e
COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_LIVE_FIXTURE="$tmp_dir/live-no-ip.json" \
COURSE_FAKE_AWS_LOG="$tmp_dir/aws-no-ip.log" COURSE_FAKE_KUBECTL_LOG="$tmp_dir/kube-no-ip.log" \
AWS_PROFILE=course AWS_REGION=ap-northeast-2 \
  bash "$root/scripts/prod-live-capacity-check.sh" course-prod "$tmp_dir/profile-no-ip.json" \
    "$tmp_dir/rejected.json" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -eq 0 || -e "$tmp_dir/rejected.json" ]]; then
  echo 'expected insufficient subnet IPs to fail without evidence output' >&2
  exit 1
fi

echo 'PASS: post-infra live capacity collection contract'
