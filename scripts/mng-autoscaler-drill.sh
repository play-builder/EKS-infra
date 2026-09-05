#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 6 ]] || { echo "Usage: $0 cluster region nodegroup pause-image@sha256:digest replicas output" >&2; exit 2; }
exec python3 "$(dirname "$0")/lib/mng-autoscaler-drill.py" "$@"
