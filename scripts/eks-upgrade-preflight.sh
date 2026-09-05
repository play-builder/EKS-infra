#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 7 ]] || { echo "Usage: $0 cluster region from-version to-version nodegroup expected-release output" >&2; exit 2; }
exec python3 "$(dirname "$0")/lib/eks-lifecycle.py" collect "$@"
