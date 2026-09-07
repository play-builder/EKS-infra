#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 -B "$root/tests/runtime-readiness-test.py" secret
echo 'PASS: ESO source/version contract and complete Pod rotation baseline'
