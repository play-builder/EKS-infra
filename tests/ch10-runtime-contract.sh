#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"

cat >"$tmp_dir/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
: "${CH10_COMMAND_LOG:?}"
: "${CH10_EXPECTED_CONTEXT:?}"
: "${CH10_EXPECTED_NAMESPACE:?}"
printf '%s\n' "$*" >>"$CH10_COMMAND_LOG"
case "$*" in
  "--context $CH10_EXPECTED_CONTEXT get nodes -o json")
    echo '{"items":[{"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}'
    ;;
  "--context $CH10_EXPECTED_CONTEXT -n argocd get application sample-app-dev -o json")
    echo '{"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}}'
    ;;
  "--context $CH10_EXPECTED_CONTEXT -n $CH10_EXPECTED_NAMESPACE get externalsecret sample-app-runtime -o json")
    echo '{"status":{"conditions":[{"type":"Ready","status":"True"}]}}'
    ;;
  "--context $CH10_EXPECTED_CONTEXT -n $CH10_EXPECTED_NAMESPACE get deployment sample-app -o json")
    echo '{"status":{"replicas":2,"availableReplicas":2}}'
    ;;
  *)
    printf 'unexpected kubectl invocation: %s\n' "$*" >&2
    exit 97
    ;;
esac
EOF
chmod +x "$tmp_dir/bin/kubectl"

run_ch10() {
  local expected_context=$1 expected_namespace=$2
  shift 2
  : >"$tmp_dir/kubectl.log"
  CH10_COMMAND_LOG="$tmp_dir/kubectl.log" \
    CH10_EXPECTED_CONTEXT="$expected_context" CH10_EXPECTED_NAMESPACE="$expected_namespace" \
    COURSE_CHECK_BIN_DIR="$tmp_dir/bin" \
    bash "$root/scripts/course-check.sh" ch10 "$@" >/dev/null
  grep -Fxq -- "--context $expected_context -n $expected_namespace get externalsecret sample-app-runtime -o json" \
    "$tmp_dir/kubectl.log"
  [[ $(wc -l <"$tmp_dir/kubectl.log" | tr -d ' ') -eq 4 ]]
}

run_ch10 course-dev app-dev
run_ch10 explicit-context explicit-namespace explicit-context explicit-namespace

echo 'PASS: Ch10 consumes the canonical Dev namespace and ExternalSecret identity'
