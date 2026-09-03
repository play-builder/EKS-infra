#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixtures="$root/tests/fixtures"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

output=$(COURSE_CHECK_BIN_DIR="$tmp_dir" bash "$root/scripts/snapshot-recovery-check.sh" \
  "$fixtures/snapshot-recovery-valid.json" "$fixtures/snapshot-quiesce-valid.json")
grep -Fq 'PASS: [STATIC] SIMULATED_CLOUD_CONTRACT' <<<"$output"

reject_mutation() {
  local expression=$1 output_file=$2 status
  jq "$expression" "$fixtures/snapshot-recovery-valid.json" >"$output_file"
  set +e
  COURSE_CHECK_BIN_DIR="$tmp_dir" bash "$root/scripts/snapshot-recovery-check.sh" "$output_file" "$fixtures/snapshot-quiesce-valid.json" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || { echo "expected recovery rejection: $expression" >&2; exit 1; }
}

reject_mutation '.recovery.namespace="app-dev"' "$tmp_dir/same-namespace.json"
reject_mutation '.recovery.pvcName="data-sample-app-postgresql-0"' "$tmp_dir/same-pvc.json"
reject_mutation '.snapshot.readyToUse=false' "$tmp_dir/not-ready.json"
reject_mutation '.snapshot.driver="other.csi.example"' "$tmp_dir/wrong-driver.json"
reject_mutation '.unexpected=true' "$tmp_dir/extra.json"

for cluster_length in 1 100; do
  cluster_name=$(printf '%*s' "$cluster_length" '' | tr ' ' a)
  candidate="$tmp_dir/cluster-$cluster_length.json"
  jq --arg arn "arn:aws:eks:ap-northeast-2:123456789012:cluster/$cluster_name" \
    '.clusterArn = $arn' "$fixtures/snapshot-recovery-valid.json" >"$candidate"
  COURSE_CHECK_BIN_DIR="$tmp_dir" bash "$root/scripts/snapshot-recovery-check.sh" "$candidate" >/dev/null
done

reject_standalone_cluster() {
  local label=$1 expression=$2 candidate status
  candidate="$tmp_dir/recovery-cluster-$label.json"
  jq "$expression" "$fixtures/snapshot-recovery-valid.json" >"$candidate"
  set +e
  COURSE_CHECK_BIN_DIR="$tmp_dir" bash "$root/scripts/snapshot-recovery-check.sh" "$candidate" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || { echo "expected recovery rejection: $label" >&2; exit 1; }
}

reject_standalone_cluster cluster-name-101 \
  '.clusterArn = ("arn:aws:eks:ap-northeast-2:123456789012:cluster/" + ("a" * 101))'
reject_standalone_cluster cluster-trailing-path '.clusterArn += "/junk"'

echo 'PASS: snapshot recovery source isolation, IRSA identity, and readyToUse contract'
