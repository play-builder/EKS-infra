#!/usr/bin/env bash
set -euo pipefail
export PYTHONDONTWRITEBYTECODE=1
root=$(cd "$(dirname "$0")/.." && pwd)
for tool in terraform helm promtool jq ruby rg yq; do
  command -v "$tool" >/dev/null || { echo "ENTERPRISE_STATIC_PREREQUISITE_MISSING: $tool" >&2; exit 69; }
done
python_bin=${ENTERPRISE_PYTHON:-python3}
"$python_bin" -c 'import yaml' || { echo 'PyYAML==6.0.3 is required for rendered chart validation; use an isolated venv.' >&2; exit 69; }
export ENTERPRISE_PYTHON="$python_bin"
command -v "${LUA_BIN:-lua}" >/dev/null || { echo 'Lua 5.1 prerequisite missing: bash scripts/install-lua.sh /path/to/bin' >&2; exit 69; }
bash "$root/tests/run-contract-tests.sh"

while IFS= read -r directory; do
  echo "STATIC Terraform mock suite: $directory"
  terraform -chdir="$root/$directory" init -backend=false -input=false -no-color
  terraform -chdir="$root/$directory" validate -no-color
  terraform -chdir="$root/$directory" test -no-color
done < <(rg --files "$root/modules" "$root/environments" "$root/terraform" -g '*.tftest.hcl' | sed "s|^$root/||; s|/tests/[^/]*$||" | sort -u)

bash "$root/tests/enterprise-native-rollouts-contract.sh"
"$python_bin" "$root/tests/ownership-marker-destroy-contract.py"
"$python_bin" "$root/tests/log-key-dag-contract.py"
"$python_bin" "$root/tests/external-secret-lua-contract.py"
bash "$root/tests/argocd-render-contract.sh"
bash "$root/tests/sigstore-controller-contract.sh"
bash "$root/tests/cluster-autoscaler-render-contract.sh"
"$python_bin" "$root/tests/adot-scrape-contract.py"
"$python_bin" "$root/tests/amp-promql-contract.py"

if [[ ${RUN_SDK_CONTRACTS:-false} == true ]]; then
  "$python_bin" -c 'import boto3, botocore; assert boto3.__version__ == "1.42.59" and botocore.__version__ == "1.42.59"' || {
    echo 'SDK prerequisites: install scripts/requirements-argocd-backup.txt into an isolated Python>=3.10 venv.' >&2; exit 69;
  }
  "$python_bin" "$root/tests/amp-slo-sdk-contract.py"
  "$python_bin" "$root/tests/argocd-backup-sdk-contract.py"
  "$python_bin" "$root/tests/rds-recovery-sdk-contract.py"
else
  echo 'NOT_RUN: optional real SDK model/serialization gates; RUN_SDK_CONTRACTS=true enables them (still no AWS calls).'
fi
echo 'STATIC_VERIFIED: mock providers, real local chart/PromQL evaluation only; LIVE_NOT_VERIFIED.'
