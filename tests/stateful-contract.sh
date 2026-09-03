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
  *" get storageclass/course-gp3 "*)
    echo '{"provisioner":"ebs.csi.aws.com","reclaimPolicy":"Delete","volumeBindingMode":"WaitForFirstConsumer","allowVolumeExpansion":true,"parameters":{"type":"gp3","encrypted":"true"}}' ;;
  *" get statefulset sample-app-postgresql "*)
    echo '{"spec":{"replicas":1},"status":{"readyReplicas":1,"currentRevision":"r1","updateRevision":"r1"}}' ;;
  *" get pvc "*)
    echo '{"items":[{"status":{"phase":"Bound"},"spec":{"storageClassName":"course-gp3"}}]}' ;;
  *" get job sample-app-migration "*)
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
  *"/products "*) echo '{"products":[{"sku":"COURSE-1"},{},{},{}]}' ;;
  *"/orders "*) echo '{"order":{"id":7,"status":"CONFIRMED","totalCents":32900}}' ;;
  *) echo "unexpected curl invocation: $*" >&2; exit 97 ;;
esac
EOF
chmod +x "$tmp_dir/bin/kubectl" "$tmp_dir/bin/curl"

run_one() {
  COURSE_CHECK_BIN_DIR="$tmp_dir/bin" \
    bash "$root/scripts/course-check.sh" stateful course-dev app-dev https://example.invalid
}

first=$(run_one)
second=$(run_one)
grep -Fq '"orderId": 7' <<<"$first"
grep -Fq '"orderId": 7' <<<"$second"
[[ $(grep -Ec 'PASS: \[STATIC\]' <<<"$first") -eq 1 ]]
! grep -Fq 'Idempotency-Key' <<<"$first"
! grep -Eq 'API_KEY|DB_PASSWORD|secret value' <<<"$first"

echo 'PASS: stateful runtime behavior contract'
