#!/usr/bin/env bash
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 -B "$root/tests/runtime-readiness-test.py" stateful
run_core_readiness() {
  python3 -B "$root/tests/runtime-readiness-test.py" core
}
run_core_readiness
echo 'PASS: Core readiness and stateful ownership, generation, and storage wiring'
