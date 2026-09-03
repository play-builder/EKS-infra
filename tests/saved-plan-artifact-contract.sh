#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/lib/evidence-common.sh"
source "$root/scripts/lib/cleanup-evidence.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
cat "$COURSE_FAKE_PLAN_JSON"
EOF
chmod +x "$tmp_dir/bin/terraform"
export PATH="$tmp_dir/bin:$PATH"

inspect() {
  COURSE_FAKE_PLAN_JSON=$1 cleanup_inspect_saved_destroy_plan \
    environments/dev/04-workloads/argocd "$tmp_dir/replacement.tfplan" \
    "$root/tests/fixtures/cleanup-ownership-valid.json" "$root" \
    course-2026 123456789012 ap-northeast-2 playdevops
}

run_rejection() {
  local fixture=$1 label=$2 output status
  set +e
  output=$(inspect "$fixture" 2>&1)
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    echo "$label artifact was accepted as a genuine no-op saved plan" >&2
    exit 1
  fi
  grep -Fq 'SAVED_DESTROY_PLAN_ARTIFACT_INVALID' <<<"$output"
}

case "${1:-all}" in
  state-shaped)
    run_rejection "$root/tests/fixtures/terraform-state-shaped.json" state-shaped
    ;;
  malformed)
    run_rejection "$root/tests/fixtures/terraform-plan-noop-malformed.json" malformed
    ;;
  managed-resource)
    run_rejection "$root/tests/fixtures/terraform-plan-noop-managed-resource.json" managed-resource
    ;;
  all)
    valid_output=''
    run_rejection "$root/tests/fixtures/terraform-state-shaped.json" state-shaped
    run_rejection "$root/tests/fixtures/terraform-plan-noop-malformed.json" malformed
    run_rejection "$root/tests/fixtures/terraform-plan-noop-managed-resource.json" managed-resource
    if ! valid_output=$(inspect "$root/tests/fixtures/terraform-plan-noop-valid.json"); then
      echo 'genuine no-op saved plan with data-only reads was rejected' >&2
      exit 1
    fi
    [[ "$valid_output" == NO_CHANGES ]] || exit 1
    echo 'PASS: no-change recovery accepts only genuine Terraform saved plan JSON'
    ;;
  *) exit 64 ;;
esac
