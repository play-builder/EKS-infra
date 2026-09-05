#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 6 ]] || { echo "Usage: $0 cluster region gitops-drill-namespace signed-image@digest unsigned-image@digest output" >&2; exit 2; }
exec python3 "$(dirname "$0")/lib/supply-chain-check.py" admission "$@"
