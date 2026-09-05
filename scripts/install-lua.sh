#!/usr/bin/env bash
set -euo pipefail
# Lua 5.1 matches the health language level; not a runtime application dependency.
# Official digest: https://www.lua.org/ftp/
destination=${1:?absolute destination bin directory required}
[[ "$destination" == /* && "$destination" != / ]] || exit 64
for tool in curl tar make cc python3; do
  command -v "$tool" >/dev/null || { echo "LUA_BUILD_PREREQUISITE_MISSING: $tool" >&2; exit 69; }
done
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
archive=${LUA_SOURCE_ARCHIVE:-$temporary/lua.tar.gz}
if [[ -z ${LUA_SOURCE_ARCHIVE:-} ]]; then
  curl --fail --location --silent --show-error https://www.lua.org/ftp/lua-5.1.5.tar.gz -o "$archive"
fi
python3 - "$archive" <<'PY'
import hashlib,pathlib,sys
actual=hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest()
if actual != "2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333":
    raise SystemExit("LUA_SOURCE_CHECKSUM_MISMATCH")
PY
tar -xzf "$archive" -C "$temporary"
make -C "$temporary/lua-5.1.5" generic
mkdir -p "$destination"
install -m 0755 "$temporary/lua-5.1.5/src/lua" "$destination/lua"
"$destination/lua" -v
