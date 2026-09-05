#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 4 ]] || { echo "Usage: $0 cluster region minimum-replicas output" >&2; exit 2; }
exec python3 "$(dirname "$0")/lib/supply-chain-check.py" controller "$@"
