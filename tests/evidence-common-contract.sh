#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/scripts/lib/evidence-common.sh"

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"

real_stat=$(command -v stat)
cat >"$tmp_dir/bin/stat" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 4 || "$1" != -c || "$2" != '%a' || "$3" != -- ]]; then
  echo 'GNU stat shim accepts only: stat -c %a -- FILE' >&2
  exit 64
fi

printf '%s\n' "$*" >>"$COURSE_FAKE_STAT_LOG"
file=$4
if mode=$("$COURSE_REAL_STAT" -c '%a' -- "$file" 2>/dev/null); then
  printf '%s\n' "$mode"
else
  "$COURSE_REAL_STAT" -f '%Lp' -- "$file"
fi
EOF
chmod +x "$tmp_dir/bin/stat"

secure_file="$tmp_dir/secure.json"
overpermissive_file="$tmp_dir/overpermissive.json"
: >"$secure_file"
: >"$overpermissive_file"
chmod 600 "$secure_file"
chmod 640 "$overpermissive_file"

COURSE_REAL_STAT="$real_stat" COURSE_FAKE_STAT_LOG="$tmp_dir/stat.log" PATH="$tmp_dir/bin:$PATH" \
  course_assert_file_mode "$secure_file" 600

set +e
output=$(COURSE_REAL_STAT="$real_stat" COURSE_FAKE_STAT_LOG="$tmp_dir/stat.log" PATH="$tmp_dir/bin:$PATH" \
  course_assert_file_mode "$overpermissive_file" 600 2>&1)
status=$?
set -e
if [[ "$status" -eq 0 ]] || ! grep -Fq 'expected 600, got 640' <<<"$output"; then
  echo 'portable mode assertion accepted an overpermissive evidence file' >&2
  exit 1
fi
[[ $(grep -Fc -- '-c %a -- ' "$tmp_dir/stat.log") -eq 2 ]] || {
  echo 'portable mode assertion bypassed the GNU stat shim' >&2
  exit 1
}

echo 'PASS: portable exact evidence file-mode contract'
