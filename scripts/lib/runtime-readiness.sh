#!/usr/bin/env bash
# Bash entry points delegate structured Kubernetes/AWS checks to one Python owner.
check_core_runtime() { runtime_readiness core "${1:-mini-commerce-dev}" "${2:-app-dev}"; }
check_stateful() { runtime_readiness stateful "$@"; }
check_secret_baseline() { runtime_readiness secret-baseline "$@"; }
check_secret_freshness() { runtime_readiness secret-freshness "$@"; }

runtime_readiness() {
  local runtime_library_dir
  runtime_library_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
  python3 -I -B "$runtime_library_dir/runtime-readiness.py" "$@"
}
