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

reject snapshot-quiesce-writer-active.json
reject snapshot-quiesce-volume-attached.json
reject snapshot-quiesce-unclean-db.json
reject snapshot-quiesce-checksum-after-stop.json

jq '.unexpected=true' "$fixtures/snapshot-quiesce-valid.json" >"$tmp_dir/extra.json"
set +e
COURSE_CHECK_BIN_DIR="$tmp_dir" bash "$root/scripts/snapshot-quiesce-check.sh" "$tmp_dir/extra.json" >/dev/null 2>&1
status=$?
set -e
[[ "$status" -ne 0 ]]

echo 'PASS: snapshot quiesce writer, clean shutdown, detach, and checksum ordering contract'
