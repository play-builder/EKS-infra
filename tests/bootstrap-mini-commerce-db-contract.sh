#!/usr/bin/env bash
set -euo pipefail
PYTHONDONTWRITEBYTECODE=1 python3 "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/bootstrap-mini-commerce-db-contract.py"
