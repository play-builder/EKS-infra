#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"

cat >"$tmp_dir/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$COURSE_FAKE_AWS_LOG"
cat "$COURSE_ADDON_FIXTURE"
EOF
cat >"$tmp_dir/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
cat "$COURSE_DAEMONSET_FIXTURE"
EOF
chmod +x "$tmp_dir/bin/aws" "$tmp_dir/bin/kubectl"

for region in ap-northeast-2 us-east-1; do
  log="$tmp_dir/$region.log"
  output=$(AWS_PROFILE=course AWS_REGION=$region COURSE_CHECK_BIN_DIR="$tmp_dir/bin" \
    COURSE_FAKE_AWS_LOG="$log" COURSE_ADDON_FIXTURE="$root/tests/fixtures/vpc-cni-network-policy-ready.json" \
    COURSE_DAEMONSET_FIXTURE="$root/tests/fixtures/vpc-cni-daemonset-ready.json" \
    bash "$root/scripts/network-policy-runtime.sh" course-dev dev-course-eks standard \
      "$root/tests/fixtures/vpc-cni-addon-lock.json")
  grep -Fq '[STATIC] SIMULATED_CLOUD_CONTRACT' <<<"$output"
  grep -Fq -- "--region $region" "$log"
done

set +e
AWS_PROFILE=course AWS_REGION=ap-northeast-2 COURSE_CHECK_BIN_DIR="$tmp_dir/bin" \
  COURSE_FAKE_AWS_LOG="$tmp_dir/bad.log" COURSE_ADDON_FIXTURE="$root/tests/fixtures/vpc-cni-network-policy-ready.json" \
  COURSE_DAEMONSET_FIXTURE="$root/tests/fixtures/vpc-cni-daemonset-not-ready.json" \
  bash "$root/scripts/network-policy-runtime.sh" course-dev dev-course-eks standard \
    "$root/tests/fixtures/vpc-cni-addon-lock.json" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]

echo 'PASS: VPC CNI manifest-bound runtime contract'
