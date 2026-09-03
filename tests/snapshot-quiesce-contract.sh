#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fixtures="$root/tests/fixtures"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT

output=$(COURSE_CHECK_BIN_DIR="$tmp_dir" bash "$root/scripts/snapshot-quiesce-check.sh" "$fixtures/snapshot-quiesce-valid.json")
grep -Fq 'PASS: [STATIC] SIMULATED_CLOUD_CONTRACT' <<<"$output"
[[ $(grep -Ec 'PASS: \[(STATIC|CLOUD_RUNTIME|INCIDENT_EVIDENCE)\]' <<<"$output") -eq 1 ]]

reject() {
  local fixture=$1 status
  set +e
  COURSE_CHECK_BIN_DIR="$tmp_dir" bash "$root/scripts/snapshot-quiesce-check.sh" "$fixtures/$fixture" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || { echo "expected rejection: $fixture" >&2; exit 1; }
}

reject_file() {
  local file=$1 label=$2 status
  set +e
  COURSE_CHECK_BIN_DIR="$tmp_dir" bash "$root/scripts/snapshot-quiesce-check.sh" "$file" >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" -ne 0 ]] || { echo "expected rejection: $label" >&2; exit 1; }
}

reject snapshot-quiesce-writer-active.json
reject snapshot-quiesce-volume-attached.json
reject snapshot-quiesce-unclean-db.json
reject snapshot-quiesce-checksum-after-stop.json

jq '.database.shutdownSignal="SIGTERM"' "$fixtures/snapshot-quiesce-valid.json" >"$tmp_dir/legacy-sigterm.json"
reject_file "$tmp_dir/legacy-sigterm.json" legacy-sigterm

reject_timestamp() {
  local label=$1 path=$2 value=$3 candidate
  candidate="$tmp_dir/timestamp-$label.json"
  jq --argjson path "$path" --arg value "$value" '
    .checksum.capturedAt = "2020-02-01T00:00:00Z" |
    .database.stoppedAt = "2020-05-01T00:00:00Z" |
    .observedAt = "2020-08-01T00:00:00Z" |
    .expiresAt = "2099-12-01T00:00:00Z" |
    setpath($path; $value)
  ' "$fixtures/snapshot-quiesce-valid.json" >"$candidate"
  reject_file "$candidate" "$label"
}

reject_timestamp captured-invalid-calendar '["checksum","capturedAt"]' '2020-02-30T00:00:00Z'
reject_timestamp stopped-invalid-calendar '["database","stoppedAt"]' '2020-04-31T00:00:00Z'
reject_timestamp observed-invalid-calendar '["observedAt"]' '2020-06-31T00:00:00Z'
reject_timestamp expires-invalid-calendar '["expiresAt"]' '2099-02-31T00:00:00Z'

reject_timestamp captured-fractional '["checksum","capturedAt"]' '2020-02-01T00:00:00.123Z'
reject_timestamp stopped-fractional '["database","stoppedAt"]' '2020-05-01T00:00:00.123Z'
reject_timestamp observed-fractional '["observedAt"]' '2020-08-01T00:00:00.123Z'
reject_timestamp expires-fractional '["expiresAt"]' '2099-12-01T00:00:00.123Z'

reject_timestamp captured-offset '["checksum","capturedAt"]' '2020-02-01T09:00:00+09:00'
reject_timestamp stopped-offset '["database","stoppedAt"]' '2020-05-01T09:00:00+09:00'
reject_timestamp observed-offset '["observedAt"]' '2020-08-01T09:00:00+09:00'
reject_timestamp expires-offset '["expiresAt"]' '2099-12-01T09:00:00+09:00'

jq '.unexpected=true' "$fixtures/snapshot-quiesce-valid.json" >"$tmp_dir/extra.json"
set +e
COURSE_CHECK_BIN_DIR="$tmp_dir" bash "$root/scripts/snapshot-quiesce-check.sh" "$tmp_dir/extra.json" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]

for cluster_length in 1 100; do
  cluster_name=$(printf '%*s' "$cluster_length" '' | tr ' ' a)
  candidate="$tmp_dir/cluster-$cluster_length.json"
  jq --arg arn "arn:aws:eks:ap-northeast-2:123456789012:cluster/$cluster_name" \
    '.clusterArn = $arn' "$fixtures/snapshot-quiesce-valid.json" >"$candidate"
  COURSE_CHECK_BIN_DIR="$tmp_dir" bash "$root/scripts/snapshot-quiesce-check.sh" "$candidate" >/dev/null
done

jq '.clusterArn = ("arn:aws:eks:ap-northeast-2:123456789012:cluster/" + ("a" * 101))' \
  "$fixtures/snapshot-quiesce-valid.json" >"$tmp_dir/cluster-101.json"
reject_file "$tmp_dir/cluster-101.json" cluster-name-101

jq '.clusterArn += "/junk"' "$fixtures/snapshot-quiesce-valid.json" >"$tmp_dir/cluster-junk.json"
reject_file "$tmp_dir/cluster-junk.json" cluster-trailing-path

echo 'PASS: snapshot quiesce writer, clean shutdown, detach, and checksum ordering contract'
