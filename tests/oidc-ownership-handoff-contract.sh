#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
valid="$root/tests/fixtures/oidc-ownership-handoff-valid.json"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"
for command in aws terraform; do
  cat >"$tmp_dir/bin/$command" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$COURSE_FAKE_MUTATION_LOG"
exit 97
EOF
  chmod +x "$tmp_dir/bin/$command"
done
: >"$tmp_dir/mutations.log"

run_oidc_handoff() {
  COURSE_CHECK_NOW=2099-01-01T00:30:00Z COURSE_FAKE_MUTATION_LOG="$tmp_dir/mutations.log" \
    PATH="$tmp_dir/bin:$PATH" bash "$root/scripts/oidc-ownership-handoff.sh" "$@"
}

output=$(run_oidc_handoff --evidence "$valid" --validate-only)
grep -Fq 'VALID: course.oidc-ownership-handoff/v1' <<<"$output"
if COURSE_CHECK_NOW=2099-02-30T00:30:00Z COURSE_FAKE_MUTATION_LOG="$tmp_dir/mutations.log" \
  PATH="$tmp_dir/bin:$PATH" bash "$root/scripts/oidc-ownership-handoff.sh" \
    --evidence "$valid" --validate-only >/dev/null 2>&1; then
  echo 'noncanonical OIDC evaluation time must be rejected' >&2
  exit 1
fi

invalid="$tmp_dir/invalid.json"

expect_timestamp_rejected() {
  local label=$1 path=$2 value=$3
  jq --argjson path "$path" --arg value "$value" 'setpath($path;$value)' "$valid" >"$invalid"
  if run_oidc_handoff --evidence "$invalid" --validate-only >/dev/null 2>&1; then
    echo "expected $label OIDC handoff timestamp to fail" >&2
    exit 1
  fi
}

for timestamp_case in \
  'invalid-calendar|2020-02-30T00:00:00Z' \
  'fractional|2020-03-01T00:00:00.123Z' \
  'offset|2020-03-01T09:00:00+09:00'; do
  IFS='|' read -r label value <<<"$timestamp_case"
  expect_timestamp_rejected "approved-$label" '["approval","approvedAt"]' "$value"
done
expect_timestamp_rejected observed-invalid-calendar '["observedAt"]' '2098-02-30T00:00:00Z'
expect_timestamp_rejected observed-fractional '["observedAt"]' '2098-03-01T00:00:00.123Z'
expect_timestamp_rejected observed-offset '["observedAt"]' '2098-03-01T09:00:00+09:00'
expect_timestamp_rejected expires-invalid-calendar '["expiresAt"]' '2099-02-30T00:00:00Z'
expect_timestamp_rejected expires-fractional '["expiresAt"]' '2099-03-01T00:00:00.123Z'
expect_timestamp_rejected expires-offset '["expiresAt"]' '2099-03-01T09:00:00+09:00'
expect_timestamp_rejected approval-after-observation '["approval","approvedAt"]' '2099-01-01T00:02:00Z'
expect_timestamp_rejected observed-in-future '["observedAt"]' '2099-01-01T00:31:00Z'
expect_timestamp_rejected expired '["expiresAt"]' '2099-01-01T00:29:00Z'

jq '.approval.approvedAt="not-a-timestamp"' "$valid" >"$invalid"
: >"$tmp_dir/mutations.log"
if run_oidc_handoff --evidence "$invalid" >/dev/null 2>&1; then
  echo 'invalid OIDC approval unexpectedly reached an operator-driven transition' >&2
  exit 1
fi
[[ ! -s "$tmp_dir/mutations.log" ]] || {
  echo 'invalid OIDC approval must fail before cloud or state mutation commands' >&2
  exit 1
}

jq '.destinationState.imported=false' "$valid" >"$invalid"
if run_oidc_handoff --evidence "$invalid" --validate-only >/dev/null 2>&1; then
  echo 'expected unimported destination to fail' >&2
  exit 1
fi

echo 'PASS: OIDC ownership handoff evidence contract'
