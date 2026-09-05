#!/usr/bin/env bash
set -Eeuo pipefail
python3 "$(dirname "$0")/eks-lifecycle-test.py"
