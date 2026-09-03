#!/usr/bin/env bash
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

tests=(
  course-check-contract.sh
  stateful-contract.sh
)

for test_file in "${tests[@]}"; do
  echo "RUN: tests/$test_file"
  bash "$root/tests/$test_file"
done

echo 'PASS: offline semantic contract suite'
