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
case "$*" in
  *"get nodes"*) jq '.nodes' "$COURSE_LIVE_FIXTURE" ;;
  *"get daemonsets"*) jq '.daemonSets' "$COURSE_LIVE_FIXTURE" ;;
  *) printf 'unexpected kubectl invocation: %s\n' "$*" >&2; exit 97 ;;
esac
EOF
cat >"$tmp_dir/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$COURSE_FAKE_AWS_LOG"
[[ "$*" == *"--region $AWS_REGION"* ]] || { echo 'missing explicit region' >&2; exit 98; }
jq '.subnets' "$COURSE_LIVE_FIXTURE"
EOF
chmod +x "$tmp_dir/bin/kubectl" "$tmp_dir/bin/aws"

jq '.profile.expiresAt="2099-02-31T00:00:00Z"' \
  "$root/tests/fixtures/game-day-live-capacity-ap-northeast-2.json" >"$tmp_dir/invalid-time-live.json"
jq '.profile' "$tmp_dir/invalid-time-live.json" >"$tmp_dir/invalid-time-profile.json"
: >"$tmp_dir/invalid-time-aws.log"
: >"$tmp_dir/invalid-time-kube.log"
if COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_LIVE_FIXTURE="$tmp_dir/invalid-time-live.json" \
  COURSE_FAKE_AWS_LOG="$tmp_dir/invalid-time-aws.log" COURSE_FAKE_KUBECTL_LOG="$tmp_dir/invalid-time-kube.log" \
  AWS_PROFILE=course AWS_REGION=ap-northeast-2 \
    bash "$root/scripts/game-day-capacity-check.sh" dev-playdevops-eks "$tmp_dir/invalid-time-profile.json" \
      "$tmp_dir/invalid-time-result.json" >/dev/null 2>&1; then
  echo 'expected invalid-calendar capacity profile expiry to fail' >&2
  exit 1
fi
if [[ -s "$tmp_dir/invalid-time-aws.log" || -s "$tmp_dir/invalid-time-kube.log" || -e "$tmp_dir/invalid-time-result.json" ]]; then
  echo 'invalid capacity profile timestamp must fail before cloud queries or evidence output' >&2
  exit 1
fi

for region in ap-northeast-2 us-east-1; do
  jq --arg region "$region" \
    '.profile.region=$region | .profile.clusterArn=("arn:aws:eks:"+$region+":123456789012:cluster/dev-playdevops-eks")' \
    "$root/tests/fixtures/game-day-live-capacity-$region.json" >"$tmp_dir/live-$region.json"
  jq '.profile' "$tmp_dir/live-$region.json" >"$tmp_dir/profile-$region.json"
  output="$tmp_dir/result-$region.json"
  COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_LIVE_FIXTURE="$tmp_dir/live-$region.json" \
    COURSE_FAKE_AWS_LOG="$tmp_dir/aws-$region.log" COURSE_FAKE_KUBECTL_LOG="$tmp_dir/kube-$region.log" \
    AWS_PROFILE=course AWS_REGION="$region" \
      bash "$root/scripts/game-day-capacity-check.sh" dev-playdevops-eks "$tmp_dir/profile-$region.json" "$output"
  jq -e --arg region "$region" \
    '.schemaVersion == "course.game-day-capacity/v1" and .evidenceGrade == "STATIC" and .decision == "GO" and .region == $region and .observations.nodes.count > 0' \
    "$output" >/dev/null
  grep -Fq -- "--context dev-playdevops-eks" "$tmp_dir/kube-$region.log"
  grep -Fq -- "--region $region" "$tmp_dir/aws-$region.log"
done

! grep -R -Fq '[CLOUD_RUNTIME]' "$tmp_dir"/result-*.json

run_cluster_boundary() {
  local label=$1 cluster_arn=$2 expectation=$3 status
  local live="$tmp_dir/cluster-$label-live.json"
  local profile="$tmp_dir/cluster-$label-profile.json"
  local result="$tmp_dir/cluster-$label-result.json"
  jq --arg arn "$cluster_arn" '.profile.clusterArn = $arn' \
    "$root/tests/fixtures/game-day-live-capacity-ap-northeast-2.json" >"$live"
  jq '.profile' "$live" >"$profile"
  set +e
  COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_LIVE_FIXTURE="$live" \
    COURSE_FAKE_AWS_LOG="$tmp_dir/cluster-$label-aws.log" \
    COURSE_FAKE_KUBECTL_LOG="$tmp_dir/cluster-$label-kube.log" \
    AWS_PROFILE=course AWS_REGION=ap-northeast-2 \
      bash "$root/scripts/game-day-capacity-check.sh" dev-playdevops-eks "$profile" "$result" >/dev/null 2>&1
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
  'arn:aws:eks:ap-northeast-2:123456789012:cluster/dev-playdevops-eks/junk' reject

jq '.subnets.Subnets[].AvailableIpAddressCount=0' \
  "$root/tests/fixtures/game-day-live-capacity-ap-northeast-2.json" >"$tmp_dir/live-no-go.json"
jq '.profile' "$tmp_dir/live-no-go.json" >"$tmp_dir/profile-no-go.json"
set +e
COURSE_CHECK_BIN_DIR="$tmp_dir/bin" COURSE_LIVE_FIXTURE="$tmp_dir/live-no-go.json" \
  COURSE_FAKE_AWS_LOG="$tmp_dir/aws-no-go.log" COURSE_FAKE_KUBECTL_LOG="$tmp_dir/kube-no-go.log" \
  AWS_PROFILE=course AWS_REGION=ap-northeast-2 \
    bash "$root/scripts/game-day-capacity-check.sh" dev-playdevops-eks "$tmp_dir/profile-no-go.json" "$tmp_dir/rejected.json" >/dev/null 2>&1
status=$?
set -e
if [[ "$status" -eq 0 || -e "$tmp_dir/rejected.json" ]]; then
  echo 'expected game-day NO_GO to fail without evidence output' >&2
  exit 1
fi

echo 'PASS: Ch25 game-day capacity collector contract'
