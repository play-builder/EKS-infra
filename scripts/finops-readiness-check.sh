#!/usr/bin/env bash
set -Eeuo pipefail
# Isolated Python ignores injected PYTHONPATH and user site packages.
exec python3 -I "$(dirname "$0")/lib/finops-readiness.py" "$@"
