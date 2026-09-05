#!/usr/bin/env bash
set -Eeuo pipefail
python3 "$(dirname "$0")/supply-chain-test.py"
