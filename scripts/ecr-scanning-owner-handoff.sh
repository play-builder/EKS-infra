#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 1 ]] || { echo "Usage: $0 saved-plan.json" >&2; exit 2; }
exec python3 "$(dirname "$0")/lib/supply-chain-check.py" handoff "$@"
