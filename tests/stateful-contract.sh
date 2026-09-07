#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"

cat >"$tmp_dir/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
args=" $* "
case "$args" in
  *" get storageclass/mini-commerce-gp3 "*)
    echo '{"provisioner":"ebs.csi.aws.com","reclaimPolicy":"Delete","volumeBindingMode":"WaitForFirstConsumer","allowVolumeExpansion":true,"parameters":{"type":"gp3","encrypted":"true"}}' ;;
  *" get statefulset mini-commerce-postgresql "*)
    echo '{"spec":{"replicas":1},"status":{"readyReplicas":1,"currentRevision":"r1","updateRevision":"r1"}}' ;;
  *" get pvc "*)
    echo '{"items":[{"status":{"phase":"Bound"},"spec":{"storageClassName":"mini-commerce-gp3"}}]}' ;;
  *" get job mini-commerce-migration "*)
    echo '{"status":{"succeeded":1,"failed":0}}' ;;
  *" get pods "*)
    echo '{"items":[{"status":{"conditions":[{"type":"Ready","status":"True"}]}}]}' ;;
  *) echo "unexpected kubectl invocation: $*" >&2; exit 97 ;;
esac
EOF

cat >"$tmp_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
args=" $* "
case "$args" in
  *"/products/1/inventory "*) echo '{"productId":1,"availableQuantity":10}' ;;
  *"/products "*) echo '{"products":[{"sku":"PB-1"},{},{},{}]}' ;;
  *"/orders "*) echo '{"order":{"id":7,"status":"CONFIRMED","totalCents":32900}}' ;;
  *) echo "unexpected curl invocation: $*" >&2; exit 97 ;;
esac
EOF
chmod +x "$tmp_dir/bin/kubectl" "$tmp_dir/bin/curl"

run_one() {
  PLATFORM_CHECK_BIN_DIR="$tmp_dir/bin" \
    bash "$root/scripts/dev-ready-check.sh" stateful mini-commerce-dev app-dev https://example.invalid
}

first=$(run_one)
second=$(run_one)
grep -Fq '"orderId": 7' <<<"$first"
grep -Fq '"orderId": 7' <<<"$second"
[[ $(grep -Ec 'PASS: \[STATIC\]' <<<"$first") -eq 1 ]]
! grep -Fq 'Idempotency-Key' <<<"$first"
! grep -Eq 'API_KEY|DB_PASSWORD|secret value' <<<"$first"

echo 'PASS: stateful runtime behavior contract'

(
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
  "--context $CH10_EXPECTED_CONTEXT -n argocd get application mini-commerce-dev -o json")
    echo '{"status":{"sync":{"status":"Synced"},"health":{"status":"Healthy"}}}'
    ;;
  "--context $CH10_EXPECTED_CONTEXT -n $CH10_EXPECTED_NAMESPACE get externalsecret mini-commerce-runtime -o json")
    echo '{"status":{"conditions":[{"type":"Ready","status":"True"}]}}'
    ;;
  "--context $CH10_EXPECTED_CONTEXT -n $CH10_EXPECTED_NAMESPACE get deployment mini-commerce -o json")
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
    PLATFORM_CHECK_BIN_DIR="$tmp_dir/bin" \
    bash "$root/scripts/dev-ready-check.sh" core "$@" >/dev/null
  grep -Fxq -- "--context $expected_context -n $expected_namespace get externalsecret mini-commerce-runtime -o json" \
    "$tmp_dir/kubectl.log"
  [[ $(wc -l <"$tmp_dir/kubectl.log" | tr -d ' ') -eq 4 ]]
}

run_ch10 mini-commerce-dev app-dev
run_ch10 explicit-context explicit-namespace explicit-context explicit-namespace

echo 'PASS: Ch10 consumes the canonical Dev namespace and ExternalSecret identity'

)
