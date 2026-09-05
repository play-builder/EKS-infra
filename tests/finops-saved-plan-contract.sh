#!/usr/bin/env bash
set -Eeuo pipefail
exec python3 -B "$(dirname "$0")/finops_saved_plan_test.py"
