#!/usr/bin/env bash
set -Eeuo pipefail
trap 'printf "ERROR: Argo CD backup command failed at line %s\n" "$LINENO" >&2' ERR
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python3 "$SCRIPT_DIR/lib/argocd-backup.py" "$@"
