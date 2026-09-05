#!/usr/bin/env bash
set -Eeuo pipefail
python3 "$(dirname "$0")/argocd-ha-test.py"
