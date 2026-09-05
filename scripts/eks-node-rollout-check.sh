#!/usr/bin/env bash
set -Eeuo pipefail
# A rollout is gated by the same full lifecycle observations, including exact MNG release.
exec bash "$(dirname "$0")/eks-upgrade-preflight.sh" "$@"
