#!/usr/bin/env bash
set -Eeuo pipefail
python3 "$(dirname "$0")/mng-autoscaler-test.py"
