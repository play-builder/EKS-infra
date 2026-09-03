#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"

cat >"$tmp_dir/bin/aws" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$1 $2" == "secretsmanager describe-secret" ]] || exit 97
cat <<'JSON'
{"ARN":"arn:aws:secretsmanager:ap-northeast-2:123456789012:secret:sample-app/dev/sample-app-runtime","VersionIdsToStages":{"runtime-v2":["AWSCURRENT"],"runtime-v1":["AWSPREVIOUS"]}}
JSON
EOF

cat >"$tmp_dir/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  *"get externalsecret sample-app-runtime"*)
    cat <<'JSON'
{"metadata":{"generation":2},"status":{"syncedResourceVersion":"runtime-v2","conditions":[{"type":"Ready","status":"True","observedGeneration":2}]}}
JSON
    ;;
  *"get rollout sample-app"*)
    echo '{"status":{"currentPodHash":"new-hash"}}'
    ;;
  *"get pods -l rollouts-pod-template-hash=new-hash"*)
    echo '{"items":[{"metadata":{"uid":"pod-new"},"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    ;;
  *) printf 'unexpected kubectl invocation: %s\n' "$*" >&2; exit 97 ;;
esac
EOF
chmod +x "$tmp_dir/bin/aws" "$tmp_dir/bin/kubectl"

output=$(AWS_PROFILE=course AWS_REGION=ap-northeast-2 COURSE_CHECK_BIN_DIR="$tmp_dir/bin" \
  bash "$root/scripts/course-check.sh" ch12 course-dev app-dev sample-app-runtime sample-app \
  sample-app/dev/sample-app-runtime runtime-v2 pod-old)
grep -Fq 'version=runtime-v2' <<<"$output"
grep -Fq '[STATIC] SIMULATED_CLOUD_CONTRACT' <<<"$output"
! grep -Fq 'secret-value' <<<"$output"

if AWS_PROFILE=course AWS_REGION=ap-northeast-2 COURSE_CHECK_BIN_DIR="$tmp_dir/bin" \
  bash "$root/scripts/course-check.sh" ch12 course-dev app-dev sample-app-db sample-app \
  sample-app/dev/sample-app-db runtime-v2 pod-old >/dev/null 2>&1; then
  echo 'DB secret must never enter the runtime reload path' >&2
  exit 1
fi

echo 'PASS: runtime secret freshness changes Pod UID without exposing secret values'
