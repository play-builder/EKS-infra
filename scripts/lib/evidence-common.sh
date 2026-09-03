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

course_assert_eks_cluster_arn() {
  local arn=$1 region=$2 account=${3:-} account_pattern='[0-9]{12}'
  course_validate_region "$region"
  if [[ -n "$account" ]]; then
    course_validate_account "$account"
    account_pattern=$account
  fi
  [[ "$arn" =~ ^arn:aws:eks:${region}:${account_pattern}:cluster/[A-Za-z0-9][A-Za-z0-9_-]{0,99}$ ]] || \
    course_fail 'invalid canonical EKS cluster ARN'
}

course_assert_canonical_utc_seconds() {
  local file=$1 label=$2 path value
  shift 2
  for path in "$@"; do
    value=$(jq -er --argjson path "$path" 'getpath($path) | select(type == "string")' "$file") || \
      course_fail "invalid canonical UTC seconds timestamp: $label"
    course_assert_canonical_utc_seconds_value "$value" "$label"
  done
}

course_assert_canonical_utc_seconds_value() {
  local value=$1 label=$2
  jq -en --arg value "$value" '
    $value |
    test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$") and
    ((try (fromdateiso8601 | todateiso8601) catch "") == .)
  ' >/dev/null || course_fail "invalid canonical UTC seconds timestamp: $label"
}

course_sha256_file() {
  shasum -a 256 "$1" | awk '{print "sha256:" $1}'
}

course_raw_sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
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

course_file_mode() {
  local file=$1 mode
  if mode=$(stat -c '%a' -- "$file" 2>/dev/null); then
    printf '%s\n' "$mode"
    return 0
  fi
  if mode=$(stat -f '%Lp' -- "$file" 2>/dev/null); then
    printf '%s\n' "$mode"
    return 0
  fi
  course_fail "unable to read file mode: $file"
}

course_assert_file_mode() {
  local file=$1 expected=$2 actual
  actual=$(course_file_mode "$file")
  [[ "$actual" == "$expected" ]] || \
    course_fail "unexpected file mode for $file: expected $expected, got $actual"
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
  chmod 600 "$output"
}

course_assert_json() {
  local file=$1 filter=$2 error=$3
  jq -e "$filter" "$file" >/dev/null || course_fail "$error"
}
