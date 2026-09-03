#!/usr/bin/env bash

course_fail() {
  printf 'ERROR: %s\n' "$1" >&2
  exit "${2:-1}"
}

course_require_file() {
  [[ -f "$1" ]] || course_fail "file not found: $1" 66
  jq -e . "$1" >/dev/null 2>&1 || course_fail "invalid JSON: $1" 65
}

course_validate_region() {
  [[ "$1" == "ap-northeast-2" || "$1" == "us-east-1" ]] || \
    course_fail "UNSUPPORTED_REGION: ${1:-<empty>}" 64
}

course_validate_account() {
  [[ "$1" =~ ^[0-9]{12}$ ]] || course_fail "invalid AWS account ID" 64
}

course_sha256_file() {
  shasum -a 256 "$1" | awk '{print "sha256:" $1}'
}

course_now() {
  jq -nr 'now | todateiso8601'
}

course_expires_after() {
  local seconds=${1:-3600}
  jq -nr --argjson seconds "$seconds" 'now + $seconds | todateiso8601'
}

course_runtime_grade() {
  if [[ -n "${COURSE_CHECK_BIN_DIR:-}" ]]; then
    printf 'STATIC'
  else
    printf 'CLOUD_RUNTIME'
  fi
}

course_write_json() {
  local output=$1 payload=$2 output_dir tmp_file
  output_dir=$(dirname -- "$output")
  [[ -d "$output_dir" ]] || course_fail "output directory not found: $output_dir" 66
  tmp_file=$(mktemp "$output.tmp.XXXXXX")
  printf '%s\n' "$payload" >"$tmp_file"
  jq -e . "$tmp_file" >/dev/null || {
    rm -f -- "$tmp_file"
    course_fail "refusing to write invalid JSON"
  }
  mv -f -- "$tmp_file" "$output"
}

course_assert_json() {
  local file=$1 filter=$2 error=$3
  jq -e "$filter" "$file" >/dev/null || course_fail "$error"
}
