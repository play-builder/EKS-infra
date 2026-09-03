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
case "$1 $2" in
  "ecr start-lifecycle-policy-preview") echo '{}' ;;
  "ecr wait") exit 0 ;;
  "ecr get-lifecycle-policy-preview") cat "$COURSE_ECR_FIXTURE" ;;
  *) exit 97 ;;
esac
EOF
chmod +x "$tmp_dir/bin/aws"

digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
for region in ap-northeast-2 us-east-1; do
  log="$tmp_dir/$region.log"
  output=$(AWS_PROFILE=course AWS_REGION=$region COURSE_CHECK_BIN_DIR="$tmp_dir/bin" \
    COURSE_FAKE_AWS_LOG="$log" COURSE_ECR_FIXTURE="$root/tests/fixtures/ecr-preview-retained-index.json" \
    bash "$root/scripts/ecr-lifecycle-preview.sh" playdevops/sample-app "$digest")
  grep -Fq 'GO' <<<"$output"
  [[ $(grep -Fc -- "--region $region" "$log") -eq 3 ]]
done

set +e
AWS_PROFILE=course AWS_REGION=ap-northeast-2 COURSE_CHECK_BIN_DIR="$tmp_dir/bin" \
  COURSE_FAKE_AWS_LOG="$tmp_dir/expire.log" COURSE_ECR_FIXTURE="$root/tests/fixtures/ecr-preview-expire-index.json" \
  bash "$root/scripts/ecr-lifecycle-preview.sh" playdevops/sample-app "$digest" >"$tmp_dir/expire.out" 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]
grep -Fq 'NO_GO' "$tmp_dir/expire.out"

for fixture in ecr-preview-in-progress.json ecr-preview-failed.json; do
  set +e
  AWS_PROFILE=course AWS_REGION=us-east-1 COURSE_CHECK_BIN_DIR="$tmp_dir/bin" \
    COURSE_FAKE_AWS_LOG="$tmp_dir/$fixture.log" COURSE_ECR_FIXTURE="$root/tests/fixtures/$fixture" \
    bash "$root/scripts/ecr-lifecycle-preview.sh" playdevops/sample-app "$digest" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]]
done

echo 'PASS: ECR lifecycle rollback-retention contract'
