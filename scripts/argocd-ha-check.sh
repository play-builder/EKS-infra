#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 5 ]] || { echo "Usage: $0 cluster region readonly-group admin-group output" >&2; exit 2; }
exec python3 "$(dirname "$0")/lib/argocd-ha-check.py" "$@"
