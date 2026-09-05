#!/usr/bin/env bash
set -Eeuo pipefail
[[ $# == 3 ]] || { echo "Usage: $0 state-show.json exact-mapping.json saved-plan.json" >&2; exit 2; }
exec python3 "$(dirname "$0")/lib/access-entry-review.py" "$@"
