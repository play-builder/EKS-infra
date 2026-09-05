#!/usr/bin/env bash
set -Eeuo pipefail
exec python3 "$(dirname "$0")/finops_readiness_test.py"
