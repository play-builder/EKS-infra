#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 5 ]] || { echo "Usage: $0 region legacy-repository new-repository image-digest output" >&2; exit 2; }
exec python3 "$(dirname "$0")/lib/supply-chain-check.py" scanning "$@"
