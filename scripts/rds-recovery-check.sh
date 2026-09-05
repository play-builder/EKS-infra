#!/usr/bin/env bash
set +x
set -euo pipefail
exec python3 "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/rds-recovery.py" "$@"
